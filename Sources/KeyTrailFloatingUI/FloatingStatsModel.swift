import Foundation
import KeyTrailIPC

public enum FloatingStatsPeriod: String, CaseIterable, Sendable {
    case currentHour
    case today

    public var title: String { self == .currentHour ? "当前小时" : "今日" }
}

/// Calendar boundaries are local boundaries, including short and long DST days.
/// The query is [start, end); zero length at the exact boundary is intentional.
public struct FloatingStatsRange: Sendable, Equatable {
    public let period: FloatingStatsPeriod
    public let start: Date
    public let end: Date

    public init(period: FloatingStatsPeriod, now: Date = Date(), calendar: Calendar = .current) throws {
        guard now.timeIntervalSince1970.isFinite,
              let interval = calendar.dateInterval(of: period == .currentHour ? .hour : .day, for: now),
              interval.start <= now, now < interval.end else {
            throw FloatingStatsError.invalidRange
        }
        self.period = period
        start = interval.start
        end = now
    }

    public var request: [String: Any] {
        ["op": "summary", "start": start.timeIntervalSince1970, "end": end.timeIntervalSince1970]
    }
}

/// Copy the IPC status into an immutable value safe to return from a polling queue.
public struct FloatingCollectorStatus: Sendable, Equatable {
    public let monitoring: Bool
    public let paused: Bool
    public let permissionGranted: Bool
    public let suspended: Bool
    public let statusText: String
    public let pid: Int
    public let backend: String
    public let isDemo: Bool

    public init(_ status: RuntimeStatus) {
        monitoring = status.monitoring
        paused = status.paused
        permissionGranted = status.permissionGranted
        suspended = status.suspended
        statusText = status.statusText
        pid = status.pid
        backend = status.backend
        isDemo = status.isDemo
    }

    public var isRecording: Bool { monitoring && !paused && permissionGranted && !suspended && !isDemo }
    public var label: String { isDemo ? "演示数据 · \(statusText)" : statusText }
}

public enum FloatingStatsError: LocalizedError {
    case invalidRange
    case invalidSummary

    public var errorDescription: String? {
        switch self {
        case .invalidRange: return "无法确定本地统计时间范围。"
        case .invalidSummary: return "后台统计响应不完整或数值无效。"
        }
    }
}

public struct FloatingStatsSnapshot: Sendable, Equatable {
    public let range: FloatingStatsRange
    public let keyPresses: Int
    public let totalClicks: Int
    /// Cursor distance in display points, never physical mouse travel.
    public let mouseDistancePoints: Double
    /// Already deduplicated by the collector; do not add keyboard and mouse times.
    public let totalActiveSeconds: Int
    public let collector: FloatingCollectorStatus
    /// Time the query range was selected, not a guarantee that every input is committed.
    public let capturedAt: Date

    public init(summary: Any, status: RuntimeStatus, range: FloatingStatsRange, capturedAt: Date) throws {
        // Decode rather than silently casting/defaulting to zero. JSONDecoder rejects
        // booleans, strings, missing fields, fractions and integers outside Int's range.
        guard JSONSerialization.isValidJSONObject(summary),
              let data = try? JSONSerialization.data(withJSONObject: summary),
              let value = try? JSONDecoder().decode(SummaryFields.self, from: data),
              value.keyPresses >= 0, value.leftClicks >= 0, value.rightClicks >= 0, value.middleClicks >= 0,
              value.totalActiveSeconds >= 0,
              value.mouseDistancePoints.isFinite, value.mouseDistancePoints >= 0,
              capturedAt.timeIntervalSince1970.isFinite else {
            throw FloatingStatsError.invalidSummary
        }
        let (leftAndRight, firstOverflow) = value.leftClicks.addingReportingOverflow(value.rightClicks)
        let (clicks, secondOverflow) = leftAndRight.addingReportingOverflow(value.middleClicks)
        guard !firstOverflow, !secondOverflow else { throw FloatingStatsError.invalidSummary }
        self.range = range
        keyPresses = value.keyPresses
        totalClicks = clicks
        mouseDistancePoints = value.mouseDistancePoints
        totalActiveSeconds = value.totalActiveSeconds
        collector = FloatingCollectorStatus(status)
        self.capturedAt = capturedAt
    }

    /// Synchronous read-only IPC; callers run this on their serialized background queue.
    /// This neither requests permission nor starts/stops/flushes the existing collector.
    public static func load(client: RuntimeClient, period: FloatingStatsPeriod,
                            now: Date = Date(), calendar: Calendar = .current) throws -> FloatingStatsSnapshot {
        let range = try FloatingStatsRange(period: period, now: now, calendar: calendar)
        let status = try client.status()
        let summary = try client.request(range.request)
        return try FloatingStatsSnapshot(summary: summary, status: status, range: range, capturedAt: now)
    }

    public func isStale(at now: Date = Date(), after threshold: TimeInterval = 10) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return !age.isFinite || age < 0 || !threshold.isFinite || threshold < 0 || age > threshold
    }

    private struct SummaryFields: Decodable {
        let keyPresses: Int
        let leftClicks: Int
        let rightClicks: Int
        let middleClicks: Int
        let mouseDistancePoints: Double
        let totalActiveSeconds: Int
    }
}

public enum FloatingStatsFormat {
    public static func count(_ value: Int) -> String {
        guard value >= 0 else { return "—" }
        return value.formatted(.number.locale(Locale(identifier: "zh_CN")))
    }

    public static func distance(_ points: Double) -> String {
        guard points.isFinite, points >= 0 else { return "—" }
        return points.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "zh_CN"))) + " 点"
    }

    public static func activity(_ seconds: Int) -> String {
        guard seconds >= 0 else { return "—" }
        if seconds >= 3600 { return "\(seconds / 3600) 时 \(twoDigits(seconds % 3600 / 60)) 分" }
        if seconds >= 60 { return "\(seconds / 60) 分 \(twoDigits(seconds % 60)) 秒" }
        return "\(seconds) 秒"
    }

    private static func twoDigits(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
}
