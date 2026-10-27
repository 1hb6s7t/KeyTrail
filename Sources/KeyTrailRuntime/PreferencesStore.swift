import Foundation
import KeyTrailIPC
import Security
import CryptoKit

struct PrivateSyncConfiguration: Codable {
    var endpoint = ""
    var deviceId = UUID().uuidString.lowercased()
    var cursor: Int64 = 0
    var replicaId: String?
    var lastSuccess: Double?
    var textCursor: Int64 = 0
    var textReplicaId: String?
    var lastTextSuccess: Double?
    enum CodingKeys: String, CodingKey { case endpoint, deviceId, cursor, replicaId, lastSuccess, textCursor, textReplicaId, lastTextSuccess }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        deviceId = try values.decodeIfPresent(String.self, forKey: .deviceId) ?? UUID().uuidString.lowercased()
        cursor = try values.decodeIfPresent(Int64.self, forKey: .cursor) ?? 0
        replicaId = try values.decodeIfPresent(String.self, forKey: .replicaId)
        lastSuccess = try values.decodeIfPresent(Double.self, forKey: .lastSuccess)
        textCursor = try values.decodeIfPresent(Int64.self, forKey: .textCursor) ?? 0
        textReplicaId = try values.decodeIfPresent(String.self, forKey: .textReplicaId)
        lastTextSuccess = try values.decodeIfPresent(Double.self, forKey: .lastTextSuccess)
    }
    var credentialAccount: String {
        Self.credentialAccount(endpoint: endpoint, deviceId: deviceId)
    }
    static func credentialAccount(endpoint: String, deviceId: String) -> String {
        "sync-" + SHA256.hash(data: Data("\(endpoint)\u{0}\(deviceId)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct StoredPreferences: Codable {
    var preferences = RuntimePreferences()
    var sync = PrivateSyncConfiguration()
}

/// Stores non-secret settings only; tokens belong in Keychain.
final class PreferencesStore {
    let url: URL
    private(set) var value: StoredPreferences

    init(directory: URL) throws {
        url = directory.appendingPathComponent("preferences.json")
        if FileManager.default.fileExists(atPath: url.path) {
            value = try JSONDecoder().decode(StoredPreferences.self, from: Data(contentsOf: url))
            value.preferences = try value.preferences.validated()
            guard value.sync.cursor >= 0, value.sync.textCursor >= 0, UUID(uuidString: value.sync.deviceId) != nil else { throw RuntimeError("同步设置无效，请检查本地配置文件。") }
        } else {
            value = StoredPreferences()
            try save(value)
        }
    }

    func save(_ next: StoredPreferences) throws {
        var next = next
        next.preferences = try next.preferences.validated()
        let data = try JSONEncoder().encode(next)
        try PrivateFile.write(data, to: url)
        value = next
    }
}

protocol SyncSecretStore: AnyObject {
    func read(account: String) throws -> String?
    func write(_ token: String, account: String) throws
}

final class KeychainSyncSecrets: SyncSecretStore {
    private let service: String
    init(isDemo: Bool) { service = RuntimePaths.keychainService("private-sync", isDemo: isDemo) }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let token = String(data: data, encoding: .utf8) else {
            throw RuntimeError("无法读取同步凭据（Keychain \(status)）。")
        }
        return token
    }
    func write(_ token: String, account: String) throws {
        let data = Data(token.utf8)
        let query = query(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw RuntimeError("无法保存同步凭据到 Keychain。") }
        } else if status != errSecSuccess { throw RuntimeError("无法更新同步凭据（Keychain \(status)）。") }
    }
}

/// Only isolated tests receive this implementation; production always uses Keychain.
final class MemorySyncSecrets: SyncSecretStore {
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func write(_ token: String, account: String) throws { values[account] = token }
}

enum SyncEndpoint {
    static func validated(_ string: String) throws -> URL {
        guard let url = URL(string: string), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())) else {
            throw RuntimeError("请输入私有服务的 HTTPS 根地址；仅本机 localhost/127.0.0.1 可用 HTTP。地址不能包含凭据、路径或查询参数。")
        }
        return url
    }
    static func validToken(_ token: String) -> Bool {
        (43...256).contains(token.utf8.count) && token.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}
