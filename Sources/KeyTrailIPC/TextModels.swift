import Foundation

public struct TextRecordingStatus: Codable, Sendable {
    public var enabled: Bool
    public var permissionGranted: Bool
    public var state: String
    public var message: String
}

public struct TextMetadata: Codable, Sendable, Identifiable {
    public var id: String
    public var timestamp: Date
    public var applicationBundleID: String
    public var characterCount: Int
    public init(id:String,timestamp:Date,applicationBundleID:String,characterCount:Int) {
        self.id=id;self.timestamp=timestamp;self.applicationBundleID=applicationBundleID;self.characterCount=characterCount
    }
}

public struct TextHistoryEntry: Codable, Sendable, Identifiable {
    public var metadata: TextMetadata
    public var text: String
    public var id: String { metadata.id }
    public init(metadata:TextMetadata,text:String) {self.metadata=metadata;self.text=text}
}

public struct TextHistoryPage: Codable, Sendable {
    public var entries: [TextHistoryEntry]
    public var matchedCount: Int
    public var scannedRecords: Int
    public var totalRecords: Int
    public var totalCharacters: Int
    public var hasMore: Bool
    public var coverageComplete: Bool
}

/// Only saved committed text contributes. This is not physical typing speed.
public struct ArchivedTextMetrics: Codable, Sendable {
    public var totalCharacters: Int64 = 0
    public var archivedActiveSeconds: Double = 0
    public var averageCharactersPerActiveMinute: Double?
    public var peakCharactersPerMinute: Int64 = 0
    public var peakMinute: Double?
    public var recordedMinutes: Int64 = 0
    public init() {}
}

/// Resume position is Unix milliseconds, unlike metadata.timestamp which is a
/// Date encoded on the wire as Unix seconds. A cursor is bound to one query/version.
public struct TextScanCursor: Codable, Sendable, Equatable {
    public let snapshotRevision:Int64
    public let timestampMilliseconds:Int64
    public let id:String
    public let queryFingerprint:String
    public init(snapshotRevision:Int64,timestampMilliseconds:Int64,id:String,queryFingerprint:String) {
        self.snapshotRevision=snapshotRevision;self.timestampMilliseconds=timestampMilliseconds;self.id=id;self.queryFingerprint=queryFingerprint
    }
}
/// Counts scanned/matched on this page only; totals cover the entire frozen range.
/// hasMore means more candidates to scan, even when entries is empty.
public struct TextScanPage: Codable, Sendable {
    public let entries:[TextHistoryEntry]
    public let scannedRecords:Int
    public let matchedCount:Int
    public let totalRecords:Int
    public let totalCharacters:Int
    public let snapshotRevision:Int64
    public let nextCursor:TextScanCursor?
    public let hasMore:Bool
    public let coverageComplete:Bool
    public init(entries:[TextHistoryEntry],scannedRecords:Int,matchedCount:Int,totalRecords:Int,totalCharacters:Int,snapshotRevision:Int64,nextCursor:TextScanCursor?,hasMore:Bool,coverageComplete:Bool) {
        self.entries=entries;self.scannedRecords=scannedRecords;self.matchedCount=matchedCount;self.totalRecords=totalRecords;self.totalCharacters=totalCharacters;self.snapshotRevision=snapshotRevision;self.nextCursor=nextCursor;self.hasMore=hasMore;self.coverageComplete=coverageComplete
    }
}
