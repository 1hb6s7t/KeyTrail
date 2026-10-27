import Foundation

public struct RuntimePreferences: Codable, Equatable, Sendable {
    public var storageLimitBytes: Int64 = 0
    public var floatingWindowEnabled = false
    public var petEnabled = false
    public var launchAtLoginEnabled = false
    public var syncEnabled = false
    public var textRecordingEnabled = false
    public var textSyncEnabled = false
    public init() {}

    enum CodingKeys: String, CodingKey { case storageLimitBytes, floatingWindowEnabled, petEnabled, launchAtLoginEnabled, syncEnabled, textRecordingEnabled, textSyncEnabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        storageLimitBytes = try values.decodeIfPresent(Int64.self, forKey: .storageLimitBytes) ?? 0
        floatingWindowEnabled = try values.decodeIfPresent(Bool.self, forKey: .floatingWindowEnabled) ?? false
        petEnabled = try values.decodeIfPresent(Bool.self, forKey: .petEnabled) ?? false
        launchAtLoginEnabled = try values.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled) ?? false
        syncEnabled = try values.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
        textRecordingEnabled = try values.decodeIfPresent(Bool.self, forKey: .textRecordingEnabled) ?? false
        textSyncEnabled = try values.decodeIfPresent(Bool.self, forKey: .textSyncEnabled) ?? false
    }

    public func validated() throws -> Self {
        guard storageLimitBytes == 0 || (1_048_576...1_099_511_627_776).contains(storageLimitBytes) else {
            throw RuntimeError("存储上限应为 1 MiB–1 TiB，或 0 表示不限。")
        }
        var value = self
        if !value.syncEnabled { value.textSyncEnabled = false }
        return value
    }
}

public struct StorageInformation: Codable, Sendable {
    public var databaseBytes: Int64 = 0
    public var textBytes: Int64 = 0
    public var textRecordCount: Int64 = 0
    public var minuteCount: Int = 0
    public var oldestMinute: Double?
    public var newestMinute: Double?
    public init() {}
    enum CodingKeys: String, CodingKey { case databaseBytes, textBytes, textRecordCount, minuteCount, oldestMinute, newestMinute }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        databaseBytes = try values.decodeIfPresent(Int64.self, forKey: .databaseBytes) ?? 0
        textBytes = try values.decodeIfPresent(Int64.self, forKey: .textBytes) ?? 0
        textRecordCount = try values.decodeIfPresent(Int64.self, forKey: .textRecordCount) ?? 0
        minuteCount = try values.decodeIfPresent(Int.self, forKey: .minuteCount) ?? 0
        oldestMinute = try values.decodeIfPresent(Double.self, forKey: .oldestMinute)
        newestMinute = try values.decodeIfPresent(Double.self, forKey: .newestMinute)
    }
}

public struct PrivateSyncStatus: Codable, Sendable {
    public var enabled = false
    public var configured = false
    public var endpoint = ""
    public var deviceId = ""
    public var cursor: Int64 = 0
    public var lastSuccess: Double?
    public var syncing = false
    public var error: String?
    public var textEnabled = false
    public var textCursor: Int64 = 0
    public var lastTextSuccess: Double?
    public init() {}
}

public struct RuntimeDetails: Codable, Sendable {
    /// Optional for compatibility with collectors released before desktop pets.
    public var petAvailable: Bool?
    public var preferences = RuntimePreferences()
    public var storage = StorageInformation()
    public var sync = PrivateSyncStatus()
    public var loginStatus = "notRegistered"
    public var retentionError: String?
    public init() {}
}
