import AppKit
import CoreGraphics
import Foundation
import KeyTrailCore
import KeyTrailIPC
import ServiceManagement
import CryptoKit

/// Shared by the resident's capacity maintenance and isolated aggregate fixtures.
/// A capacity check is not an input interruption: only actual cleanup may end
/// transient windows before deleting rows that those windows could recreate.
public enum RuntimeRetentionMaintenance {
    public static func combinedBytes(statistics: Int64, text: Int64) throws -> Int64 {
        let (bytes, overflow) = statistics.addingReportingOverflow(text)
        guard statistics >= 0, text >= 0, !overflow else { throw RuntimeError("联合数据库容量无效或溢出。") }
        return bytes
    }

    public static func applyCombinedLimit(maxBytes: Int64, flush: @escaping (_ endActivity: Bool) throws -> Void,
                                         databaseBytes: () throws -> Int64, retain: (_ beforeDeleting: () throws -> Void) throws -> Bool,
                                         didRetain: () -> Void) throws -> Bool {
        guard maxBytes >= 1_048_576 else { throw RuntimeError("存储上限至少为 1 MiB。") }
        // Include pending aggregates without losing the unobserved 30-second tail.
        try flush(false)
        let bytes = try databaseBytes()
        guard bytes >= 0 else { throw RuntimeError("联合数据库容量无效。") }
        guard bytes > maxBytes else { return true }
        var endedActivity = false
        let met = try retain {
            guard !endedActivity else { return }
            try flush(true)
            endedActivity = true
        }
        if endedActivity { didRetain() }
        return met
    }
}

@MainActor
public final class RuntimeController {
    public let isDemo: Bool
    public let directory: URL
    public var onStatusChange: ((RuntimeStatus) -> Void)?
    public var onShutdown: (() -> Void)?
    public var onPreferencesChange: (() -> Void)?
    public var petAvailable = false
    private let store: RustStore
    private let monitor = InputMonitor()
    private let petAnimation = PetAnimationState()
    private var server: RuntimeServer?
    private var pending: [InputSample] = []
    private var timer: Timer?
    private var resumeTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var monitoring = false
    private var startedOnce = false
    private var suspensionReasons = Set<String>()
    private var systemSuspended: Bool { !suspensionReasons.isEmpty }
    private var secureSuspended = false
    private var statusText = "尚未开始记录 · Rust 后台就绪"
    private var lastTick = Date()
    private var lastCommit: Date?
    private var recoveryCutoff: Date?
    private var terminated = false
    private let settings: PreferencesStore
    private let syncSecrets: SyncSecretStore
    private var privateSync: PrivateSync?
    private var maintenanceTimer: Timer?
    private var lastRetentionCheck = Date.distantPast
    private var retentionError: String?
    private let textCapture: TextCapture
    private var textArchive: TextArchive?
    private let usesFixtureDirectory: Bool
    private var textWriteError: String?

    public var preferences: RuntimePreferences { settings.value.preferences }

    /// Status for an enabled monitor; suspension has priority over recording.
    public nonisolated static func runningStatusText(systemSuspended: Bool, secureSuspended: Bool) -> String {
        if systemSuspended { return "锁屏或休眠 · 采集暂停" }
        if secureSuspended { return "安全输入中 · 采集暂停" }
        return "正在本机记录 · Rust 核心"
    }

    public init(isDemo: Bool, directory: URL? = nil) throws {
        guard directory == nil || isDemo else {
            throw RuntimeError("自定义测试目录仅允许演示模式使用，不能用于真实输入采集。")
        }
        self.isDemo = isDemo
        self.directory = directory ?? RuntimePaths.directory(isDemo: isDemo)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let db = self.directory.appendingPathComponent("activity.sqlite")
        let existed = FileManager.default.fileExists(atPath: db.path)
        store = try RustStore(url: db)
        settings = try PreferencesStore(directory: self.directory)
        // An explicitly injected fixture directory never accesses the user's Keychain.
        syncSecrets = directory == nil ? KeychainSyncSecrets(isDemo: isDemo) : MemorySyncSecrets()
        usesFixtureDirectory = directory != nil
        textCapture = TextCapture(isDemo: isDemo)
        if isDemo {
            if !existed { try seedDemo() }
            statusText = "演示模式 · Rust 后台 · 不监听输入"
        }
        monitor.onPetInput = { [weak self] event in
            guard let self else { return }
            guard self.settings.value.preferences.petEnabled, self.monitoring, !self.isDemo,
                  !self.systemSuspended, !self.secureSuspended, !self.monitor.secureInputEnabled else {
                self.petAnimation.reset(); return
            }
            switch event {
            case .key(let code, let isDown, let autorepeat): self.petAnimation.key(code: code, isDown: isDown, autorepeat: autorepeat)
            case .mouse(let button, let isDown): self.petAnimation.mouse(button: button, isDown: isDown)
            case .gaze(let x, let y): self.petAnimation.gaze(x: x, y: y)
            case .scroll: self.petAnimation.scroll()
            case .reset: self.petAnimation.reset()
            }
        }
        monitor.petInputEnabled = settings.value.preferences.petEnabled
        monitor.onSample = { [weak self] sample in
            guard let self, self.monitoring, !self.systemSuspended, !self.secureSuspended else { return }
            if self.settings.value.preferences.textRecordingEnabled {
                if sample.kind == .keyPress { self.textCapture.observeIntent(.keyPress, at: sample.timestamp) }
                else if sample.kind == .leftClick { self.textCapture.observeIntent(.pointer, at: sample.timestamp) }
            }
            self.pending.append(sample)
            if self.pending.count >= 32_000 {
                do { try self.flush(at: sample.timestamp) }
                catch { self.fail(error); return }
            }
        }
        monitor.onInterruption = { [weak self] message in
            guard let self else { return }
            do { try self.pause(); self.statusText = message; self.notify() }
            catch { self.fail(error) }
        }
        installObservers()
        textCapture.onText = { [weak self] value in
            guard let self, self.monitoring, self.settings.value.preferences.textRecordingEnabled,
                  !self.systemSuspended, !self.secureSuspended, !self.isDemo else { return }
            do {
                _ = try self.archive(create: true)?.append(text: value.text, at: value.timestamp, applicationBundleID: value.applicationBundleID)
                self.textWriteError = nil
            } catch {
                self.textWriteError = "文字保存失败，已停止文字采集：\(error.localizedDescription)"
                self.textCapture.disable()
            }
        }
        if settings.value.preferences.textRecordingEnabled && !isDemo { _ = textCapture.enable() }
        privateSync = PrivateSync(settings: settings, secrets: syncSecrets, query: { [weak self] request in
            guard let self else { throw RuntimeError("后台已退出。") }
            return try self.store.request(request)
        }, textChanges: { [weak self] cursor in
            guard let self else { throw RuntimeError("后台已退出。") }
            return try self.archive(create: false)?.syncChanges(after: cursor, limit: 50) ?? TextChangePage(changes: [], cursor: cursor, hasMore: false)
        })
        let maintenance = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.maintain() }
        }
        maintenance.tolerance = 0.1
        RunLoop.main.add(maintenance, forMode: .common); maintenanceTimer = maintenance
    }

    public var status: RuntimeStatus {
        RuntimeStatus(monitoring: monitoring, paused: startedOnce && !monitoring, permissionGranted: monitor.hasPermission, suspended: systemSuspended || secureSuspended,
                      statusText: statusText, pid: Int(ProcessInfo.processInfo.processIdentifier), backend: "rust", isDemo: isDemo)
    }

    public func startServer() throws {
        let server = try RuntimeServer(url: directory.appendingPathComponent("engine.sock")) { [weak self] request in
            DispatchQueue.main.sync {
                guard let self else { return ["ok": false, "error": "后台已退出。"] }
                return self.handle(request)
            }
        }
        self.server = server
        server.start()
    }

    public func handle(_ request: [String: Any]) -> [String: Any] {
        do {
            let result: Any
            switch request["op"] as? String {
            case "status": result = try statusObject()
            case "petState", "resetPetPose":
                // A bounded current pose only; reset is not an input injection
                // and neither path writes statistics, text, or preferences.
                if request["op"] as? String == "resetPetPose" { petAnimation.reset() }
                let suspended = !monitoring || systemSuspended || secureSuspended || monitor.secureInputEnabled
                if preferences.petEnabled && !suspended { monitor.reconcilePetInputs(petAnimation) }
                result = try jsonValue(petAnimation.snapshot(enabled: preferences.petEnabled, suspended: suspended))
            case "start", "resume":
                try start(requestPermission: request["requestPermission"] as? Bool ?? false)
                result = try statusObject()
            case "pause":
                let minutes = request["minutes"] as? Int
                if let minutes, !(1...1440).contains(minutes) { throw RuntimeError("暂停分钟数应在 1–1440 之间。") }
                try pause(minutes: minutes); result = try statusObject()
            case "suspend": try suspend(reason: "external"); result = try statusObject()
            case "wake": wake(reason: "external"); result = try statusObject()
            case "summary", "timeline", "summaries", "trend", "insights": result = try store.request(request)
            case "storageInfo": result = try jsonValue(storageInformation())
            case "preferences": result = try detailsObject()
            case "setPreferences":
                guard let object = request["preferences"] as? [String: Any] else { throw RuntimeError("缺少偏好设置。") }
                let value = try JSONDecoder().decode(RuntimePreferences.self, from: JSONSerialization.data(withJSONObject: object))
                try setPreferences(value, requestTextPermission: request["requestTextPermission"] as? Bool ?? false)
                result = try detailsObject()
            case "textStatus":
                var value = try jsonValue(textCapture.status) as? [String: Any] ?? [:]
                if let textWriteError { value["state"] = "writeFailed"; value["message"] = textWriteError }
                result = value
            case "textSearch":
                let interval = try textInterval(request)
                if let archive = try archive(create: isDemo && !usesFixtureDirectory) {
                    result = try jsonValue(archive.search(start: interval.start, end: interval.end, keyword: request["keyword"] as? String ?? "", offset: request["offset"] as? Int ?? 0, limit: request["limit"] as? Int ?? 100))
                } else { result = ["entries": [], "matchedCount": 0, "scannedRecords": 0, "totalRecords": 0, "totalCharacters": 0, "hasMore": false, "coverageComplete": true] as [String: Any] }
            case "textSearchPage":
                let interval = try textInterval(request)
                let cursor: TextScanCursor?
                if let object = request["cursor"] {
                    cursor = try JSONDecoder().decode(TextScanCursor.self, from: JSONSerialization.data(withJSONObject: object))
                } else { cursor = nil }
                if let archive = try archive(create: isDemo && !usesFixtureDirectory) {
                    result = try jsonValue(archive.searchPage(start: interval.start, end: interval.end,
                        keyword: request["keyword"] as? String ?? "", cursor: cursor, limit: request["limit"] as? Int ?? 100))
                } else {
                    guard cursor == nil else { throw RuntimeError("文字归档已变化，请重新搜索。") }
                    result = ["entries": [], "matchedCount": 0, "scannedRecords": 0, "totalRecords": 0,
                              "totalCharacters": 0, "snapshotRevision": 0, "hasMore": false, "coverageComplete": true] as [String: Any]
                }
            case "textValidateSnapshot":
                guard let revision = request["snapshotRevision"] as? Int64, revision >= 0 else { throw RuntimeError("缺少有效的文字快照版本。") }
                if let archive = try archive(create: false) { try archive.validateSnapshot(revision: revision) }
                else if revision != 0 { throw RuntimeError("文字归档已变化，请重新搜索。") }
                result = NSNull()
            case "textMetrics":
                let interval = try textInterval(request)
                if let archive = try archive(create: false) { result = try jsonValue(archive.metrics(start: interval.start, end: interval.end)) }
                else { result = try jsonValue(ArchivedTextMetrics()) }
            case "textDelete":
                if let archive = try archive(create: false) {
                    if let ids = request["ids"] as? [String] { try archive.delete(ids: ids) }
                    else { let interval = try textInterval(request); try archive.delete(start: interval.start, end: interval.end) }
                }
                textCapture.resetBaseline(); result = NSNull()
            case "textClear":
                try archive(create: false)?.clear(); textCapture.resetBaseline(); result = NSNull()
            case "textExport":
                let interval = try textInterval(request)
                result = try archive(create: false)?.exportTXT(start: interval.start, end: interval.end, keyword: request["keyword"] as? String ?? "") ?? "所选时段没有文字记录。"
            case "textViewingKey":
                guard let archive = try archive(create: false) else { throw RuntimeError("尚无文字记录，也没有可分享的文字密钥。") }
                result = archive.exportKey()
            case "syncStatus": result = try jsonValue(privateSync?.status ?? PrivateSyncStatus())
            case "configureSync":
                try configureSync(request)
                result = try detailsObject()
            case "syncNow":
                guard settings.value.preferences.syncEnabled else { throw RuntimeError("请先开启并配置私有同步。") }
                privateSync?.pump(force: true)
                result = try jsonValue(privateSync?.status ?? PrivateSyncStatus())
            case "buckets":
                var query = request
                if let start = request["start"] as? Double, let end = request["end"] as? Double {
                    query["stepSeconds"] = end - start > 172_800 ? 3600 : 60
                }
                query["includeKeyCounts"] = false
                result = try store.request(query)
            case "export": try flush(at: Date()); result = try store.request(request)
            case "exportPage":
                if request["cursor"] == nil { try flush(at: Date()) }
                result = try store.request(request)
            case "exportValidate": result = try store.request(request)
            case "delete":
                try flush(at: Date(), end: true)
                let interval = try textInterval(request)
                if let archive = try archive(create: false) {
                    try archive.deleteTogetherWithStatistics(at: directory.appendingPathComponent("activity.sqlite"), start: interval.start, end: interval.end)
                    result = NSNull()
                } else { result = try store.request(request) }
                monitor.resetAnchors(); textCapture.resetBaseline()
            case "clear":
                monitor.stop(); monitoring = false; timer?.invalidate(); timer = nil
                textCapture.resetBaseline()
                resumeTimer?.invalidate(); resumeTimer = nil
                do {
                    try flush(at: Date(), end: true)
                    if let archive = try archive(create: false) {
                        try archive.clearTogetherWithStatistics(at: directory.appendingPathComponent("activity.sqlite")); result = NSNull()
                    } else { result = try store.request(request) }
                }
                catch { fail(error); throw error }
                pending.removeAll(keepingCapacity: false)
                recoveryCutoff = nil
                statusText = "全部统计已清空 · 采集已暂停"; notify()
            case "shutdown":
                try pause()
                result = NSNull()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.onShutdown?() }
            default: throw RuntimeError("不支持的本地操作。")
            }
            return ["ok": true, "result": result]
        } catch { return ["ok": false, "error": error.localizedDescription] }
    }

    public func start(requestPermission: Bool = false) throws {
        guard !isDemo else { throw RuntimeError("演示模式不监听真实输入。") }
        if recoveryCutoff != nil { try flush(at: Date(), end: true) }
        if !monitor.hasPermission && requestPermission { _ = CGRequestListenEventAccess() }
        guard monitor.hasPermission else {
            statusText = "等待输入监控授权"; notify()
            throw RuntimeError("请在系统设置 → 隐私与安全性 → 输入监控中允许主应用 KeyTrail，再重新打开主应用并开始记录。")
        }
        guard monitor.start() else { throw RuntimeError("只读监听启动失败，请检查 KeyTrail 的输入监控权限。") }
        resumeTimer?.invalidate(); resumeTimer = nil
        monitoring = true; startedOnce = true; secureSuspended = monitor.secureInputEnabled
        if settings.value.preferences.textRecordingEnabled { _ = textCapture.enable(requestPermission: false) }
        monitor.suspended = systemSuspended || secureSuspended
        lastTick = Date(); statusText = Self.runningStatusText(systemSuspended: systemSuspended, secureSuspended: secureSuspended)
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer.tolerance = 0.15
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        notify()
    }

    public func pause(minutes: Int? = nil) throws {
        petAnimation.reset()
        textCapture.resetBaseline()
        defer { monitor.stop(); monitoring = false; timer?.invalidate(); timer = nil; notify() }
        resumeTimer?.invalidate(); resumeTimer = nil
        let cutoff = Date()
        do { try flush(at: cutoff, end: true) }
        catch {
            if recoveryCutoff == nil { recoveryCutoff = cutoff }
            statusText = "采集已暂停，待重试保存：\(error.localizedDescription)"
            throw error
        }
        if let minutes {
            statusText = "已暂停 \(minutes) 分钟"
            let timer = Timer(timeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    do { try self.start() } catch { self.fail(error) }
                }
            }
            RunLoop.main.add(timer, forMode: .common); resumeTimer = timer
        } else { statusText = "已暂停 · 等待手动恢复" }
    }

    public func shutdown() {
        guard !terminated else { return }; terminated = true
        petAnimation.reset()
        monitor.stop(); timer?.invalidate(); resumeTimer?.invalidate()
        textCapture.disable()
        maintenanceTimer?.invalidate(); maintenanceTimer = nil; privateSync?.shutdown()
        try? flush(at: Date(), end: true)
        server?.stop(); server = nil
        for (center, token) in observers { center.removeObserver(token) }
        for token in distributedObservers { DistributedNotificationCenter.default().removeObserver(token) }
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        return try JSONSerialization.jsonObject(with: encoder.encode(value))
    }

    private func textInterval(_ request: [String: Any]) throws -> DateInterval {
        guard let start = request["start"] as? Double, let end = request["end"] as? Double,
              start.isFinite, end.isFinite, start >= 0, end >= start else { throw RuntimeError("文字查询时间范围无效。") }
        return DateInterval(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end))
    }

    private func archive(create: Bool) throws -> TextArchive? {
        if let textArchive { return textArchive }
        let url = directory.appendingPathComponent("text.sqlite")
        let existed = FileManager.default.fileExists(atPath: url.path)
        guard existed || create else { return nil }
        let key = isDemo || usesFixtureDirectory ? SymmetricKey(data: Data(SHA256.hash(data: Data("KeyTrail public isolated demo text key v1".utf8)))) : nil
        let archive = try TextArchive(url: url, key: key, keychainService: RuntimePaths.keychainService("text", isDemo: isDemo), keychainAccount: "archive-v1")
        if isDemo && !usesFixtureDirectory && !existed {
            let day = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            for (index, text) in ["【演示文字】今天完成了键迹的月报。", "【演示文字】中文输入与 emoji：你好 👋", "【演示文字】可按关键词搜索，也可以删除单条记录。"].enumerated() {
                _ = try archive.append(text: text, at: day.addingTimeInterval(Double(index * 60)), applicationBundleID: "com.auriel.keytrail.demo")
            }
        }
        self.textArchive = archive
        return archive
    }

    private var loginStatus: String {
        guard !isDemo, Bundle.main.bundleIdentifier == "com.auriel.keytrail" else { return "unavailableInPreview" }
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    private func storageInformation() throws -> StorageInformation {
        let storage = try store.request(["op": "storageInfo"])
        var information = try JSONDecoder().decode(StorageInformation.self, from: JSONSerialization.data(withJSONObject: storage))
        // Preferences and capacity are metadata-only. Opening TextArchive here
        // would request an encryption key and could block all IPC on a system
        // consent dialog even while text recording is off.
        if let text = try TextArchive.storageInfo(at: directory.appendingPathComponent("text.sqlite")) {
            information.textBytes = text.bytes
            information.textRecordCount = text.records
            information.databaseBytes = try RuntimeRetentionMaintenance.combinedBytes(statistics: information.databaseBytes, text: text.bytes)
        }
        return information
    }

    private func detailsObject() throws -> Any {
        var details = RuntimeDetails()
        details.preferences = settings.value.preferences
        details.petAvailable = petAvailable
        details.storage = try storageInformation()
        details.sync = privateSync?.status ?? PrivateSyncStatus()
        details.loginStatus = loginStatus
        details.retentionError = retentionError
        return try jsonValue(details)
    }

    private func setPreferences(_ proposed: RuntimePreferences, requestTextPermission: Bool = false) throws {
        let value = try proposed.validated()
        let previous = settings.value
        if value.syncEnabled && previous.sync.endpoint.isEmpty { throw RuntimeError("请先填写私有同步地址与采集端令牌。") }
        let textChanged = value.textRecordingEnabled != previous.preferences.textRecordingEnabled
        let loginChanged = value.launchAtLoginEnabled != previous.preferences.launchAtLoginEnabled
        if loginChanged && (isDemo || Bundle.main.bundleIdentifier != "com.auriel.keytrail") {
            throw RuntimeError("预览与开发运行不会注册系统登录项。")
        }
        var committed = false, changedLogin = false
        defer {
            if !committed {
                if textChanged && value.textRecordingEnabled { textCapture.disable() }
                if changedLogin {
                    if previous.preferences.launchAtLoginEnabled { try? SMAppService.mainApp.register() }
                    else { try? SMAppService.mainApp.unregister() }
                }
            }
        }
        if textChanged && value.textRecordingEnabled {
            guard !isDemo, textCapture.enable(requestPermission: requestTextPermission) else { throw RuntimeError(textCapture.status.message) }
            do { _ = try archive(create: true) }
            catch { textCapture.disable(); throw error }
        }
        if loginChanged {
            if value.launchAtLoginEnabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            changedLogin = true
        }
        var next = previous; next.preferences = value
        try settings.save(next); committed = true
        if previous.preferences.petEnabled != value.petEnabled { petAnimation.reset() }
        monitor.petInputEnabled = value.petEnabled
        if textChanged && !value.textRecordingEnabled { textCapture.disable() }
        if textChanged { textWriteError = nil }
        if previous.preferences.syncEnabled != value.syncEnabled || previous.preferences.textSyncEnabled != value.textSyncEnabled { privateSync?.reset() }
        if previous.preferences.storageLimitBytes != value.storageLimitBytes { lastRetentionCheck = .distantPast; retentionError = nil }
        onPreferencesChange?()
        maintain()
    }

    private func configureSync(_ request: [String: Any]) throws {
        guard let endpointText = request["endpoint"] as? String else { throw RuntimeError("缺少同步服务地址。") }
        let endpoint = try SyncEndpoint.validated(endpointText)
        let token = request["token"] as? String ?? ""
        let deviceId = request["deviceId"] as? String ?? settings.value.sync.deviceId
        guard UUID(uuidString: deviceId) != nil, SyncEndpoint.validToken(token) else { throw RuntimeError("设备 ID 或采集端令牌格式不正确。") }
        privateSync?.reset()
        try syncSecrets.write(token, account: PrivateSyncConfiguration.credentialAccount(endpoint: endpoint.absoluteString, deviceId: deviceId))
        var next = settings.value
        if next.sync.endpoint != endpoint.absoluteString || next.sync.deviceId != deviceId {
            next.sync.cursor = 0; next.sync.replicaId = nil; next.sync.lastSuccess = nil
            next.sync.textCursor = 0; next.sync.textReplicaId = nil; next.sync.lastTextSuccess = nil
        }
        next.sync.endpoint = endpoint.absoluteString; next.sync.deviceId = deviceId
        // Save configuration and enable only through the explicit UI operation.
        next.preferences.syncEnabled = request["enabled"] as? Bool ?? false
        if !next.preferences.syncEnabled { next.preferences.textSyncEnabled = false }
        try settings.save(next)
        onPreferencesChange?()
        privateSync?.pump(force: true)
    }

    private func maintain() {
        guard !terminated else { return }
        let limit = settings.value.preferences.storageLimitBytes
        if limit > 0, Date().timeIntervalSince(lastRetentionCheck) >= 60 {
            lastRetentionCheck = Date()
            do {
                let met: Bool
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("text.sqlite").path) {
                    met = try RuntimeRetentionMaintenance.applyCombinedLimit(maxBytes: limit,
                        flush: { try self.flush(at: Date(), end: $0) },
                        databaseBytes: { try self.storageInformation().databaseBytes },
                        retain: { beforeDeleting in
                            guard let archive = try self.archive(create: false) else { throw RuntimeError("文字数据库在容量检查后已变化。") }
                            return try archive.retentionTogetherWithStatistics(at: self.directory.appendingPathComponent("activity.sqlite"), maxBytes: limit, beforeDeleting: beforeDeleting).limitMet
                        }, didRetain: { self.monitor.resetAnchors(); self.textCapture.resetBaseline() })
                } else {
                    let result = try store.request(["op": "retention", "maxBytes": limit]) as? [String: Any]
                    met = result?["limitMet"] as? Bool == true
                }
                retentionError = met ? nil : "已清理可淘汰的旧记录；防止同步数据复活所需的删除记录仍占用空间，当前未达到上限。可调高上限。"
            } catch { retentionError = "自动保留策略未完成：\(error.localizedDescription)" }
        }
        privateSync?.pump()
    }

    public func systemDidSleep() { do { try suspend(reason: "sleep") } catch { fail(error) } }
    public func systemDidWake() { wake(reason: "sleep") }
    public func screenDidLock() { do { try suspend(reason: "lock") } catch { fail(error) } }
    public func screenDidUnlock() { wake(reason: "lock") }

    private func tick() {
        guard monitoring else { return }
        let now = Date()
        do {
            guard monitor.hasPermission else { try pause(); statusText = "输入监控权限已撤销"; notify(); return }
            if now.timeIntervalSince(lastTick) > 5 {
                try flush(at: max(lastTick, lastCommit ?? lastTick), end: true)
                monitor.resetAnchors()
            }
            let secure = monitor.secureInputEnabled
            if secure != secureSuspended {
                try flush(at: now, end: true)
                secureSuspended = secure; monitor.suspended = secure || systemSuspended; monitor.resetAnchors()
                textCapture.resetBaseline()
                statusText = Self.runningStatusText(systemSuspended: systemSuspended, secureSuspended: secureSuspended)
                notify()
            }
            if !systemSuspended && !secureSuspended { try flush(at: now) }
        } catch { fail(error) }
        lastTick = now
    }

    private func flush(at time: Date, end: Bool = false) throws {
        if let cutoff = recoveryCutoff {
            try flushPending(at: cutoff, end: true)
            recoveryCutoff = nil
        }
        try flushPending(at: time, end: end)
    }

    private func flushPending(at time: Date, end: Bool) throws {
        let batch = pending.filter { $0.timestamp <= time }
        if !batch.isEmpty {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
            let samples = try JSONSerialization.jsonObject(with: encoder.encode(batch))
            _ = try store.request(["op": "ingest", "samples": samples, "observedThrough": time.timeIntervalSince1970])
            pending.removeAll { $0.timestamp <= time }; lastCommit = time
        }
        _ = try store.request(["op": end ? "end" : "advance", "time": time.timeIntervalSince1970])
        lastCommit = time
    }

    private func suspend(reason: String) throws {
        petAnimation.reset()
        textCapture.resetBaseline()
        suspensionReasons.insert(reason); monitor.suspended = true
        let cutoff = Date()
        do { try flush(at: cutoff, end: true) }
        catch { if recoveryCutoff == nil { recoveryCutoff = cutoff }; fail(error); throw error }
        if monitoring { statusText = "锁屏或休眠 · 采集暂停"; notify() }
    }
    private func wake(reason: String) {
        suspensionReasons.remove(reason); monitor.suspended = secureSuspended || systemSuspended
        monitor.resetAnchors(); lastTick = Date()
        if monitoring {
            statusText = Self.runningStatusText(systemSuspended: systemSuspended, secureSuspended: secureSuspended)
            notify()
        }
    }
    private func fail(_ error: Error) {
        petAnimation.reset()
        if recoveryCutoff == nil { recoveryCutoff = Date() }
        monitor.stop(); monitoring = false; timer?.invalidate(); timer = nil
        textCapture.resetBaseline()
        resumeTimer?.invalidate(); resumeTimer = nil
        statusText = "采集已停止：\(error.localizedDescription)"; notify()
    }
    private func notify() { onStatusChange?(status) }
    private func statusObject() throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            self?.systemDidSleep()
        } }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.systemDidWake() } }))
        let center = DistributedNotificationCenter.default()
        distributedObservers.append(center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in
            self?.screenDidLock()
        } })
        distributedObservers.append(center.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.screenDidUnlock() } })
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.monitor.resetAnchors() } }))
    }

    private func seedDemo() throws {
        let calendar = Calendar.current, now = Date()
        let today = calendar.startOfDay(for: now)
        let labels = ["E", "A", "S", "D", "R", "T", "N", "I", "O", "Space", "Delete", "Return", "Cmd", "C", "V"]
        for offset in -7...0 {
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            var samples: [[String: Any]] = []
            for minute in stride(from: 480, to: 1260, by: 3) {
                let start = date.addingTimeInterval(Double(minute * 60))
                guard start.addingTimeInterval(59) < now else { continue }
                let count = 30 + abs((minute * 17 + offset * 31) % 95)
                for i in 0..<count {
                    samples.append(["timestamp": start.timeIntervalSince1970 + Double(i) / 5, "kind": "keyPress", "keyLabel": labels[(i + minute) % labels.count]])
                }
                for i in 0..<12 {
                    samples.append(["timestamp": start.timeIntervalSince1970 + Double(i * 3), "kind": "mouseMove", "distancePoints": Double(70 + (minute + i) % 400)])
                    if i % 3 == 0 { samples.append(["timestamp": start.timeIntervalSince1970 + Double(i * 3 + 1), "kind": "leftClick"]) }
                }
                samples.append(["timestamp": start.timeIntervalSince1970 + 14, "kind": "rightClick"])
                samples.append(["timestamp": start.timeIntervalSince1970 + 25, "kind": "scroll", "scrollDelta": 12])
            }
            if !samples.isEmpty {
                let end = min(calendar.date(byAdding: .day, value: 1, to: date)!, now)
                _ = try store.request(["op": "ingest", "samples": samples, "observedThrough": end.timeIntervalSince1970])
                _ = try store.request(["op": "end", "time": end.timeIntervalSince1970])
            }
        }
    }
}
