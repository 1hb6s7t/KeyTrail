import Foundation

public struct OverviewTrendSegment: Sendable {
    /// Exact clipped query bounds; displayStart is the containing civil boundary.
    public let start: Date
    public let end: Date
    public let displayStart: Date
}

public struct OverviewTrendPoint: Identifiable, Sendable {
    public let start: Date
    public let keys: Int
    public let clicks: Int
    public var id: Date { start }
}

/// One bounded calendar plan shared by the query and its chart. Large selections
/// never materialize their historical hourly buckets just to sum them again in UI.
public struct OverviewTrendPlan: Sendable {
    public let component: Calendar.Component
    public let calendar: Calendar
    public let segments: [OverviewTrendSegment]

    public init(interval: DateInterval, observedThrough: Date = Date(), calendar: Calendar = .current, preferMonthly: Bool = false) throws {
        let start = interval.start.timeIntervalSince1970, end = interval.end.timeIntervalSince1970
        guard start.isFinite, end.isFinite, observedThrough.timeIntervalSince1970.isFinite,
              start >= 0, end >= start, end < 1e12, start.truncatingRemainder(dividingBy: 60) == 0,
              interval.duration <= 100 * 366 * 86400 else { throw Self.failure("趋势时间范围无效或超过 100 年预算。") }
        self.calendar = calendar
        if interval.duration > 31 * 365.25 * 86400 { component = .year }
        else if preferMonthly || interval.duration > 370 * 86400 { component = .month }
        else { component = interval.duration > 172800 ? .day : .hour }
        let cutoff = max(interval.start, min(interval.end, observedThrough))
        var cursor = interval.start, result: [OverviewTrendSegment] = []
        while cursor < cutoff {
            guard result.count < 400, let civil = calendar.dateInterval(of: component, for: cursor) else {
                throw Self.failure("趋势范围超过 400 个日历分段，或日历边界不可用。")
            }
            let next: Date, displayStart: Date
            if component == .hour {
                // A fixed elapsed hour crosses a civil-hour boundary after a
                // 30-minute DST jump. Walk minute boundaries and merge repeated
                // local hours, as the weekly heatmap does.
                let prefix = calendar.dateComponents([.era, .year, .month, .day, .hour], from: cursor)
                // Foundation's elapsed-hour interval can begin in the preceding
                // civil hour at a half-hour DST boundary. Find its actual label
                // boundary too, including a selection that starts mid-hour.
                var labelStart = cursor
                for _ in 0..<360 {
                    let previous = labelStart.addingTimeInterval(-60)
                    guard calendar.dateComponents([.era, .year, .month, .day, .hour], from: previous) == prefix else { break }
                    labelStart = previous
                }
                displayStart = labelStart
                var boundary = min(cutoff, cursor.addingTimeInterval(60))
                while boundary < cutoff && calendar.dateComponents([.era, .year, .month, .day, .hour], from: boundary) == prefix {
                    boundary = min(cutoff, boundary.addingTimeInterval(60))
                }
                next = boundary
            } else { next = min(cutoff, civil.end); displayStart = civil.start }
            guard next > cursor, next.timeIntervalSince(cursor) <= 367 * 86400,
                  cursor.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 else {
                throw Self.failure("该日历边界无法以分钟精度查询。")
            }
            result.append(OverviewTrendSegment(start: cursor, end: next, displayStart: displayStart))
            cursor = next
        }
        segments = result
    }

    public var queryRanges: [[String: Double]] {
        segments.map { ["start": $0.start.timeIntervalSince1970, "end": $0.end.timeIntervalSince1970] }
    }

    public func points(for buckets: [MinuteBucket]) throws -> [OverviewTrendPoint] {
        guard buckets.count == segments.count,
              zip(buckets, segments).allSatisfy({ abs($0.start.timeIntervalSince($1.start)) < 0.001 }) else {
            throw Self.failure("趋势返回的时间区间不匹配，请刷新重试。")
        }
        return zip(buckets, segments).map { bucket, segment in
            OverviewTrendPoint(start: segment.displayStart, keys: bucket.summary.keyPresses, clicks: bucket.summary.totalClicks)
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "KeyTrail.OverviewTrend", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
