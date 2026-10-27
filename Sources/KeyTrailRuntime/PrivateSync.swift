import Foundation
import KeyTrailIPC

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The resident agent alone reads the journal and advances acknowledgements.
/// A failed request never advances the durable cursor; retry is idempotent.
@MainActor
final class PrivateSync {
    private let settings: PreferencesStore
    private let secrets: SyncSecretStore
    private let query: ([String: Any]) throws -> Any
    private let textChanges: (Int64) throws -> TextChangePage
    private var session: URLSession?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var schedule = PrivateSyncSchedule()
    private(set) var lastError: String?

    init(settings: PreferencesStore, secrets: SyncSecretStore, query: @escaping ([String: Any]) throws -> Any, textChanges: @escaping (Int64) throws -> TextChangePage) {
        self.settings = settings; self.secrets = secrets; self.query = query; self.textChanges = textChanges
    }

    private func activeSession() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        self.session = session
        return session
    }

    var status: PrivateSyncStatus {
        let value = settings.value
        var result = PrivateSyncStatus()
        result.enabled = value.preferences.syncEnabled
        result.configured = !value.sync.endpoint.isEmpty
        result.endpoint = value.sync.endpoint
        result.deviceId = value.sync.deviceId
        result.cursor = value.sync.cursor
        result.lastSuccess = value.sync.lastSuccess
        result.syncing = task != nil
        result.error = lastError
        result.textEnabled = value.preferences.textSyncEnabled
        result.textCursor = value.sync.textCursor
        result.lastTextSuccess = value.sync.lastTextSuccess
        return result
    }

    func reset() {
        generation &+= 1
        task?.cancel(); task = nil
        session?.invalidateAndCancel(); session = nil
        schedule = PrivateSyncSchedule(); lastError = nil
    }

    func shutdown() { reset() }

    func pump(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard settings.value.preferences.syncEnabled, !settings.value.sync.endpoint.isEmpty,
              task == nil, schedule.shouldInspect(at: now, force: force) else { return }
        schedule.inspected(at: now)
        do {
            if !schedule.shouldContactRemote(at: now, pendingChanges: false, force: force) {
                // Empty journals are checked locally before reading credentials or creating
                // a session. Heartbeats and forced/retry attempts still check remote replicas.
                // These reads never acknowledge work; catch-up re-reads the durable cursors.
                let cursor = settings.value.sync.cursor
                guard let page = try query(["op": "syncChanges", "after": cursor, "limit": 1]) as? [String: Any],
                      let changes = page["changes"] as? [[String: Any]],
                      let pageCursor = (page["cursor"] as? NSNumber)?.int64Value,
                      pageCursor >= cursor else { throw RuntimeError("本地同步日志返回无效游标。") }
                var pending = !changes.isEmpty
                if !pending && settings.value.preferences.textSyncEnabled {
                    let textCursor = settings.value.sync.textCursor
                    let page = try textChanges(textCursor)
                    guard page.cursor >= textCursor else { throw RuntimeError("文字同步日志游标无效。") }
                    pending = !page.changes.isEmpty
                }
                guard pending else { return }
            }
        } catch {
            schedule.failed(at: now); lastError = error.localizedDescription
            return
        }
        let run = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if run == self.generation { self.task = nil } }
            guard run == self.generation, !Task.isCancelled else { return }
            do {
                let config = self.settings.value.sync
                let endpoint = try SyncEndpoint.validated(config.endpoint)
                guard let token = try self.secrets.read(account: config.credentialAccount), SyncEndpoint.validToken(token) else {
                    throw RuntimeError("缺少有效的采集端令牌，请重新配置私有同步。")
                }
                let remote = try await self.http(endpoint: endpoint, route: "api/status", token: token)
                guard run == self.generation, !Task.isCancelled else { return }
                guard let replica = remote["replicaId"] as? String, !replica.isEmpty,
                      remote["deviceId"] as? String == config.deviceId else {
                    throw RuntimeError("服务端绑定的采集设备不匹配，请核对设备 ID。")
                }
                if self.settings.value.sync.replicaId != replica {
                    var changed = self.settings.value
                    changed.sync.replicaId = replica; changed.sync.cursor = 0
                    try self.settings.save(changed)
                }
                // Bound catch-up work so large histories do not monopolize the agent.
                for _ in 0..<8 {
                    guard run == self.generation, !Task.isCancelled else { return }
                    let cursor = self.settings.value.sync.cursor
                    guard let page = try self.query(["op": "syncChanges", "after": cursor, "limit": 500]) as? [String: Any],
                          let changes = page["changes"] as? [[String: Any]],
                          let pageCursor = (page["cursor"] as? NSNumber)?.int64Value,
                          pageCursor >= cursor else { throw RuntimeError("本地同步日志返回无效游标。") }
                    if changes.isEmpty { break }
                    let result = try await self.http(endpoint: endpoint, route: "api/sync", token: token,
                                                    body: ["deviceId": config.deviceId, "changes": changes])
                    guard run == self.generation, !Task.isCancelled else { return }
                    guard let acknowledged = (result["cursor"] as? NSNumber)?.int64Value,
                          acknowledged >= pageCursor else { throw RuntimeError("服务端未确认完整批次，保留本地日志以重试。") }
                    var saved = self.settings.value
                    saved.sync.cursor = pageCursor
                    saved.sync.lastSuccess = Date().timeIntervalSince1970
                    try self.settings.save(saved)
                    if page["hasMore"] as? Bool != true { break }
                }
                if self.settings.value.preferences.textSyncEnabled {
                    guard let textReplica = remote["textReplicaId"] as? String, !textReplica.isEmpty else {
                        throw RuntimeError("服务端尚不支持文字密文同步；统计同步已独立处理。")
                    }
                    if self.settings.value.sync.textReplicaId != textReplica {
                        var changed = self.settings.value
                        changed.sync.textReplicaId = textReplica; changed.sync.textCursor = 0
                        try self.settings.save(changed)
                    }
                    for _ in 0..<8 {
                        guard run == self.generation, !Task.isCancelled else { return }
                        let cursor = self.settings.value.sync.textCursor
                        let page = try self.textChanges(cursor)
                        guard page.cursor >= cursor else { throw RuntimeError("文字同步日志游标无效。") }
                        if page.changes.isEmpty { break }
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
                        let changes = try JSONSerialization.jsonObject(with: encoder.encode(page.changes))
                        let result = try await self.http(endpoint: endpoint, route: "api/text-sync", token: token,
                                                        body: ["deviceId": config.deviceId, "changes": changes])
                        guard run == self.generation, !Task.isCancelled else { return }
                        guard let acknowledged = (result["cursor"] as? NSNumber)?.int64Value, acknowledged >= page.cursor else {
                            throw RuntimeError("服务端未确认文字批次，将保留密文日志以重试。")
                        }
                        var saved = self.settings.value
                        saved.sync.textCursor = page.cursor; saved.sync.lastTextSuccess = Date().timeIntervalSince1970
                        try self.settings.save(saved)
                        if !page.hasMore { break }
                    }
                }
                guard run == self.generation, !Task.isCancelled else { return }
                self.schedule.succeeded(at: ProcessInfo.processInfo.systemUptime); self.lastError = nil
            } catch {
                guard run == self.generation, !Task.isCancelled else { return }
                self.schedule.failed(at: ProcessInfo.processInfo.systemUptime)
                self.lastError = error.localizedDescription
            }
        }
    }

    private func http(endpoint: URL, route: String, token: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint.appendingPathComponent(route))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard request.httpBody!.count <= 1_900_000 else { throw RuntimeError("同步批次超过服务端限制，未推进游标。") }
        }
        let (data, response) = try await activeSession().data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RuntimeError("同步服务未返回 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else {
            throw RuntimeError(http.statusCode == 401 || http.statusCode == 403 ? "同步认证失败，请核对令牌与设备绑定。" : "同步服务暂不可用（HTTP \(http.statusCode)），将自动重试。")
        }
        guard data.count <= 1_048_576,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["ok"] as? Bool == true,
              let result = envelope["result"] as? [String: Any] else { throw RuntimeError("同步服务返回无效数据，未推进同步游标。") }
        return result
    }
}
