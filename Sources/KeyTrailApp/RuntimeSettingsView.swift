import AppKit
import KeyTrailIPC
import SwiftUI

@MainActor
struct RuntimeSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var draft = RuntimePreferences()
    @State private var preferencesBaseline: RuntimePreferences?
    @State private var endpointBaseline = ""
    @State private var deviceIdBaseline = ""
    @State private var capEnabled = false
    @State private var capMiB = 64.0
    @State private var endpoint = ""
    @State private var token = ""
    @State private var deviceId = ""
    @State private var pendingPreferences: RuntimePreferences?
    @State private var pendingPreferencesBaseline: RuntimePreferences?
    @State private var confirmRetention = false
    @State private var localNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.runtimeSettingsLoading && model.runtimeDetails == nil {
                RhythmCard(title: "正在读取后台设置", eyebrow: "RESIDENT AGENT SETTINGS") {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("读取本地设置、存储与同步状态…") }
                        .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 12)
                }
            }
            if let details = model.runtimeDetails {
                preferencesCard(details)
                syncCard(details)
            }
            if let error = model.runtimeSettingsError {
                RhythmCard(title: "后台设置需要重试", eyebrow: "RUNTIME RESPONSE") {
                    Text(error).font(.system(size: 12)).foregroundStyle(TrailStyle.orange).textSelection(.enabled)
                    Button("重新读取设置") { model.refreshRuntimeDetails() }.controlSize(.small)
                }
            } else if model.runtimeDetails == nil && !model.runtimeSettingsLoading {
                Button("读取后台设置") { model.refreshRuntimeDetails() }.controlSize(.small)
            }
            if let notice = localNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(TrailStyle.muted).textSelection(.enabled)
            }
        }
        .onAppear { loadDraft(); model.refreshRuntimeDetails() }
        .onDisappear { token = "" }
        .onChange(of: model.runtimeDetails?.preferences) { _, _ in loadPreferences() }
        .onChange(of: model.runtimeDetails?.sync.endpoint) { _, value in
            let incoming = value ?? ""
            if endpoint == endpointBaseline { endpoint = incoming }
            endpointBaseline = incoming
        }
        .onChange(of: model.runtimeDetails?.sync.deviceId) { _, value in
            let incoming = value ?? ""
            if deviceId == deviceIdBaseline { deviceId = incoming }
            deviceIdBaseline = incoming
        }
        .confirmationDialog("允许按存储上限自动清理统计与文字密文？", isPresented: $confirmRetention, titleVisibility: .visible) {
            Button("保存并允许清理旧数据", role: .destructive) {
                if model.runtimeDetails?.preferences != pendingPreferencesBaseline {
                    model.preferencesSaveState = .failed("确认期间后台设置发生了变化，请重新核对后保存。")
                } else if let pendingPreferences {
                    model.updateRuntimePreferences(pendingPreferences, reportSaveResult: true)
                }
                self.pendingPreferences = nil
                self.pendingPreferencesBaseline = nil
            }
            Button("取消", role: .cancel) { pendingPreferences = nil; pendingPreferencesBaseline = nil }
        } message: {
            Text("两库合计上限为 \(bytes(pendingPreferences?.storageLimitBytes ?? 0))。后台会自动清理旧的分钟统计、按键频次、节奏记录及文字密文；相应同步开启后，对应删除也会传播到你的私有端。不能撤销，元数据可能使上限暂时无法满足。")
        }
    }

    private func preferencesCard(_ details: RuntimeDetails) -> some View {
        RhythmCard(title: "后台、启动与存储", eyebrow: "EXPLICIT LOCAL PREFERENCES") {
            Toggle("显示桌面数据浮窗", isOn: preferenceBinding(\.floatingWindowEnabled))
            Text("关闭看板后仍可查看按键、点击、光标距离与活跃时长。新版浮窗支持今日／当前小时、收起和置顶；旧版后台仅支持当前小时。无需额外采集权限。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
            Toggle("显示 BongoCat 桌面小猫", isOn: preferenceBinding(\.petEnabled))
                .disabled(details.petAvailable != true)
                .help("按实际物理键位显示原版对应动画；没有素材的键不亮起其他键。当前键位仅用于本机动画，不保存按键顺序。")
            Text(details.petAvailable == true
                 ? (model.isDemo ? "预览模式只检查小猫窗口，不监听真实键鼠。拖动调整位置，双击打开键迹，右键隐藏。"
                    : "键盘与鼠标动作会带动小猫。拖动调整位置，双击打开键迹，右键可暂停记录或隐藏。关闭看板后小猫继续陪伴。")
                 : "当前后台未包含桌宠组件。安装带桌宠的新版后台后可开启；现有统计可以继续使用。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
            Divider().padding(.vertical, 5)
            Toggle("登录 Mac 后启动菜单栏后台", isOn: preferenceBinding(\.launchAtLoginEnabled))
                .disabled(!loginAvailable(details))
            Text(loginAvailable(details)
                 ? "默认关闭；保存开启后，登录时启动后台，已有输入监听授权时会自动开始记录。使用 macOS 登录项目机制。"
                 : "当前构建不支持登录后自动启动，因此此项不可修改。其他后台设置仍可正常保存；这不影响已授权的键鼠记录。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            Text("系统登录状态：\(loginLabel(details.loginStatus))").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            Divider().padding(.vertical, 5)
            Toggle("开启可选文字记录", isOn: preferenceBinding(\.textRecordingEnabled)).disabled(model.isDemo)
            Text(model.isDemo ? "演示/预览构建不采集真实文字。" : "默认关闭；保存开启后，需通过 macOS 正常辅助功能授权。安全输入、受保护或无法访问的控件不会保证记录；不读取剪贴板。文字归档在本机加密保存。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            Divider().padding(.vertical, 5)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本地数据库合计 \(bytes(details.storage.databaseBytes))").font(.system(size: 13, weight: .medium))
                    Text("\(details.storage.minuteCount.formatted()) 个统计分钟 · \(details.storage.textRecordCount.formatted()) 条文字密文记录")
                        .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                    Text("其中，文字密文库占 \(bytes(details.storage.textBytes))")
                        .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                }
                Spacer()
                Button { model.refreshRuntimeDetails() } label: { Label("刷新状态", systemImage: "arrow.clockwise") }.controlSize(.small)
            }.padding(.vertical, 5)
            Toggle("启用本地数据存储上限（统计 + 文字密文）", isOn: Binding(get: { capEnabled }, set: { capEnabled = $0; model.clearPreferencesSaveFeedback() }))
            if capEnabled {
                HStack(spacing: 8) {
                    TextField("上限 MiB", value: Binding(get: { capMiB }, set: { capMiB = $0; model.clearPreferencesSaveFeedback() }), format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 120)
                    Text("MiB · 1–1,048,576，按整数保存").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                }
                Text("上限覆盖统计与文字密文两库。保存后会自动清理旧的分钟聚合、节奏和文字密文；相应同步开启后，删除会分别传播。清理不能撤销，元数据可能使合计仍超过上限。")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.orange).lineSpacing(4)
            } else {
                Text("默认不限存储；关闭上限不会恢复已删除的历史记录。")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }
            if let error = preferencesError { Text(error).font(.system(size: 11)).foregroundStyle(TrailStyle.orange) }
            if let error = details.retentionError {
                Text("清理状态：\(error)").font(.system(size: 11)).foregroundStyle(TrailStyle.orange).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Button(model.preferencesSaveState.isSaving ? "正在保存…" : "保存后台设置") { savePreferences(previous: details.preferences) }
                    .disabled(model.runtimeSettingsLoading || preferencesError != nil || desiredPreferences == details.preferences)
                    .controlSize(.small)
                if model.preferencesSaveState.isSaving { ProgressView().controlSize(.small) }
            }.padding(.top, 5)
            preferencesSaveFeedback
        }
        .font(.system(size: 12))
        .disabled(model.preferencesSaveState.isSaving)
    }

    private func syncCard(_ details: RuntimeDetails) -> some View {
        RhythmCard(title: "你的私有聚合同步", eyebrow: "PRIVATE ENDPOINT  /  OFF BY DEFAULT") {
            Toggle("允许同步到已配置的私有服务", isOn: Binding(get: { details.preferences.syncEnabled }, set: { enabled in
                var preferences = details.preferences; preferences.syncEnabled = enabled
                if !enabled { preferences.textSyncEnabled = false }
                model.updateRuntimePreferences(preferences)
            })).disabled(model.runtimeSettingsLoading || (!details.sync.configured && !details.preferences.syncEnabled))
            Text("默认关闭。开启后发送分钟聚合、各键次数及删除变更；文字密文仍需下方另行开启，剪贴板不采集。手机只能查看。开发验证使用独立演示数据，不上传真实用户数据。")
                .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            Toggle("另行开启加密文字同步", isOn: Binding(get: { details.preferences.textSyncEnabled }, set: { enabled in
                var preferences = details.preferences; preferences.textSyncEnabled = enabled
                model.updateRuntimePreferences(preferences)
            })).disabled(model.runtimeSettingsLoading || !details.preferences.syncEnabled || !details.sync.configured)
            Text("默认关闭；仅在私有同步开启时可启用。文字在本机加密后发送，仍包含时间、应用标识与字符数等元数据；手机需你明确复制的查看密钥才能解密。此开关不会自动开启文字采集。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            if model.isDemo {
                Label("当前为演示数据库；预览不读取真实统计数据库。", systemImage: "sparkles")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.orange)
            }
            Divider().padding(.vertical, 5)
            VStack(alignment: .leading, spacing: 10) {
                TextField("HTTPS 私有服务根地址", text: $endpoint).textFieldStyle(.roundedBorder)
                SecureField("采集端 token（不会回显）", text: $token).textFieldStyle(.roundedBorder).privacySensitive()
                HStack(spacing: 8) {
                    TextField("采集设备标识", text: $deviceId).textFieldStyle(.roundedBorder)
                    Button("复制标识") {
                        NSPasteboard.general.clearContents()
                        localNotice = NSPasteboard.general.setString(deviceId, forType: .string) ? "设备标识已复制。" : "设备标识复制失败。"
                    }.disabled(deviceId.isEmpty)
                    Button("生成新标识") { deviceId = UUID().uuidString }
                }
                Text("设备标识需与私有服务授权一致；更换标识不会绕过设备隔离。输入框不保存 token 偏好或日志；凭据由本机后台存入钥匙串，不在状态中回显。")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
                if let error = syncConfigurationError { Text(error).font(.system(size: 10)).foregroundStyle(TrailStyle.orange) }
                HStack(spacing: 10) {
                    Button("保存并开启同步") { configureSync(enabled: true) }
                    Button(details.preferences.syncEnabled ? "仅保存并关闭同步" : "仅保存，不启用") { configureSync(enabled: false) }
                }.controlSize(.small).disabled(model.runtimeSettingsLoading || syncConfigurationError != nil)
                Text("保存连接需要重新输入采集端 token；仅保存不会启动上传。开启后后台会重试未确认的增量与删除记录。")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
            }
            Divider().padding(.vertical, 5)
            syncStatus(details)
        }.font(.system(size: 12))
    }

    private func syncStatus(_ details: RuntimeDetails) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(details.sync.syncing ? "正在同步…" : (details.sync.enabled ? "同步已开启" : "同步已关闭"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(details.sync.error == nil ? "立即同步" : "重试同步") { model.syncNow() }
                    .disabled(!details.sync.enabled || !details.sync.configured || details.sync.syncing || model.runtimeSettingsLoading)
                    .controlSize(.small)
            }
            Text("连接：\(details.sync.configured ? "已配置" : "未配置") · 聚合已确认游标：\(details.sync.cursor)")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            if let time = details.sync.lastSuccess, time.isFinite {
                Text("最后聚合成功同步：\(Date(timeIntervalSince1970: time).formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second()))")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            } else { Text("尚无聚合成功同步记录").font(.system(size: 10)).foregroundStyle(TrailStyle.muted) }
            Text("文字密文：\(details.sync.textEnabled ? "已开启" : "已关闭") · 已确认游标：\(details.sync.textCursor)")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            if let time = details.sync.lastTextSuccess, time.isFinite {
                Text("最后文字密文成功同步：\(Date(timeIntervalSince1970: time).formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second()))")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            } else { Text("尚无文字密文成功同步记录").font(.system(size: 10)).foregroundStyle(TrailStyle.muted) }
            if let error = details.sync.error { Text(error).font(.system(size: 11)).foregroundStyle(TrailStyle.orange).textSelection(.enabled) }
        }
    }

    private var desiredPreferences: RuntimePreferences {
        var preferences = draft
        if let details = model.runtimeDetails {
            // Unsupported controls cannot contribute a stale edit to another setting's save.
            if !loginAvailable(details) { preferences.launchAtLoginEnabled = details.preferences.launchAtLoginEnabled }
            if details.petAvailable != true { preferences.petEnabled = details.preferences.petEnabled }
            preferences.syncEnabled = details.preferences.syncEnabled
            preferences.textSyncEnabled = details.preferences.textSyncEnabled
        }
        if !capEnabled { preferences.storageLimitBytes = 0 }
        else if capMiB.isFinite, (1...1_048_576).contains(capMiB) {
            preferences.storageLimitBytes = Int64(capMiB.rounded()) * 1_048_576
        }
        return preferences
    }

    private var preferencesError: String? {
        if capEnabled && (!capMiB.isFinite || !(1...1_048_576).contains(capMiB)) { return "请输入 1–1,048,576 MiB 的有限数值。" }
        return nil
    }

    private var syncConfigurationError: String? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return "请输入 HTTPS 私有服务根地址，不含内嵌凭据、子路径、查询参数或片段。" }
        guard UUID(uuidString: deviceId.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else { return "请输入有效 UUID 设备标识（可生成新标识），并确保与服务端授权一致。" }
        guard (43...256).contains(token.utf8.count), token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return "请输入服务端配置的 43–256 位 token，仅含英文字母、数字、连字符 - 与下划线 _；已有凭据不会回显。" }
        return nil
    }

    private func savePreferences(previous: RuntimePreferences) {
        guard preferencesError == nil else { return }
        let value = desiredPreferences
        if value.storageLimitBytes > 0 && (previous.storageLimitBytes == 0 || value.storageLimitBytes < previous.storageLimitBytes) {
            pendingPreferences = value; pendingPreferencesBaseline = previous; confirmRetention = true
        } else { model.updateRuntimePreferences(value, reportSaveResult: true) }
    }

    private func configureSync(enabled: Bool) {
        guard syncConfigurationError == nil else { return }
        model.configurePrivateSync(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), token: token, deviceId: deviceId.trimmingCharacters(in: .whitespacesAndNewlines), enabled: enabled)
        token = ""
        localNotice = enabled ? "已提交保存与开启请求；请以下方后台同步状态为准。" : "已提交仅保存请求；请以下方后台关闭状态为准。"
    }

    private func loadDraft() {
        loadPreferences()
        endpoint = model.runtimeDetails?.sync.endpoint ?? ""
        deviceId = model.runtimeDetails?.sync.deviceId ?? ""
        endpointBaseline = endpoint
        deviceIdBaseline = deviceId
    }

    private func loadPreferences() {
        guard let preferences = model.runtimeDetails?.preferences else { return }
        if let baseline = preferencesBaseline {
            // Refresh clean fields while retaining each unsaved local edit.
            for keyPath in [\RuntimePreferences.floatingWindowEnabled, \.petEnabled, \.launchAtLoginEnabled, \.textRecordingEnabled] {
                if draft[keyPath: keyPath] == baseline[keyPath: keyPath] {
                    draft[keyPath: keyPath] = preferences[keyPath: keyPath]
                }
            }
            let baselineCapMiB = baseline.storageLimitBytes > 0 ? Double(baseline.storageLimitBytes) / 1_048_576 : 64
            if capEnabled == (baseline.storageLimitBytes > 0), capMiB == baselineCapMiB {
                loadStorageLimit(preferences.storageLimitBytes)
            }
            // These controls save independently; the main save must keep their latest values.
            draft.syncEnabled = preferences.syncEnabled
            draft.textSyncEnabled = preferences.textSyncEnabled
        } else {
            draft = preferences
            loadStorageLimit(preferences.storageLimitBytes)
        }
        preferencesBaseline = preferences
    }

    private func loadStorageLimit(_ limit: Int64) {
        draft.storageLimitBytes = limit
        capEnabled = limit > 0
        capMiB = limit > 0 ? Double(limit) / 1_048_576 : 64
    }

    private func preferenceBinding(_ keyPath: WritableKeyPath<RuntimePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { draft[keyPath: keyPath] }, set: {
            draft[keyPath: keyPath] = $0
            model.clearPreferencesSaveFeedback()
        })
    }

    private func loginAvailable(_ details: RuntimeDetails) -> Bool {
        !model.isDemo && details.loginStatus != "unavailableInPreview"
    }

    @ViewBuilder
    private var preferencesSaveFeedback: some View {
        switch model.preferencesSaveState {
        case .idle:
            if let preferences = model.runtimeDetails?.preferences, desiredPreferences != preferences {
                Text("有尚未保存的更改。")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
            }
        case .saving:
            Text("正在保存并核对后台实际设置…")
                .font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
        case .saved:
            Label("后台设置已保存，并已核对生效状态。", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
        case .failed(let message):
            Text("保存未确认：\(message)")
                .font(.system(size: 11)).foregroundStyle(TrailStyle.orange).textSelection(.enabled)
        }
    }

    private func bytes(_ count: Int64) -> String {
        count == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }

    private func loginLabel(_ status: String) -> String {
        switch status {
        case "enabled": return "已注册并启用"
        case "requiresApproval": return "等待你在系统设置中允许"
        case "notRegistered": return "未注册"
        case "notFound": return "系统尚未找到应用"
        case "unavailableInPreview": return "预览/开发构建不可用"
        default: return "未知（\(status)），以系统设置为准"
        }
    }
}
