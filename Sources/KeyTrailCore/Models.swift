import Foundation

public enum InputKind: String, Codable, Sendable {
    case keyPress, mouseMove, leftClick, rightClick, middleClick, scroll
}

public struct InputSample: Codable, Sendable {
    public var timestamp: Date
    public var kind: InputKind
    public var keyLabel: String?
    public var distancePoints: Double
    public var scrollDelta: Double
    public init(timestamp: Date = Date(), kind: InputKind, keyLabel: String? = nil, distancePoints: Double = 0, scrollDelta: Double = 0) {
        self.timestamp = timestamp; self.kind = kind; self.keyLabel = keyLabel
        self.distancePoints = distancePoints; self.scrollDelta = scrollDelta
    }
}

public struct ActivitySummary: Codable, Sendable {
    public var keyPresses: Int = 0
    public var leftClicks: Int = 0
    public var rightClicks: Int = 0
    public var middleClicks: Int = 0
    public var mouseDistancePoints: Double = 0
    public var scrollUnits: Double = 0
    public var keyboardActiveSeconds: Int = 0
    public var mouseActiveSeconds: Int = 0
    public var totalActiveSeconds: Int = 0
    public var keyCounts: [String: Int] = [:]
    public var minuteCount: Int = 0
    public var peakKeysPerMinute: Int = 0
    public var totalClicks: Int { leftClicks + rightClicks + middleClicks }
    public var averageKeysPerMinute: Double { keyboardActiveSeconds > 0 ? Double(keyPresses) * 60 / Double(keyboardActiveSeconds) : 0 }
    public init() {}
}

public struct MinuteBucket: Codable, Sendable, Identifiable {
    public var start: Date
    public var summary: ActivitySummary
    public var id: Date { start }
    public init(start: Date, summary: ActivitySummary) { self.start = start; self.summary = summary }
}
