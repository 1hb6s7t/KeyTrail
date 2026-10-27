import Foundation

/// Explicit mutation feedback is separate from routine read/refresh errors.
public enum RuntimePreferencesSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(String)

    public var isSaving: Bool { if case .saving = self { return true }; return false }
}

public enum RuntimePreferencesSubmission {
    public static func validate(_ proposed: RuntimePreferences, current: RuntimeDetails?, isDemo: Bool) throws -> RuntimePreferences {
        let value = try proposed.validated()
        guard let current else { throw RuntimeError("尚未读取后台设置，请刷新后重试。") }
        if value.launchAtLoginEnabled != current.preferences.launchAtLoginEnabled,
           isDemo || current.loginStatus == "unavailableInPreview" {
            throw RuntimeError("当前采集版本不支持登录时启动。请保持该项原值后保存其他设置。")
        }
        return value
    }

    public static func confirm(_ proposed: RuntimePreferences, actual: RuntimePreferences) throws {
        guard proposed == actual else {
            throw RuntimeError("后台返回的设置与本次提交不同，请核对页面中的实际状态。")
        }
    }
}
