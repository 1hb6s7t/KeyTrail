import Foundation

/// Historical selections can change through retention or another client. They
/// receive a bounded refresh while visible, instead of remaining cached forever.
public enum DashboardRefreshPolicy {
    public static let historicalInterval: TimeInterval = 30

    public static func isDue(since previous: Date, at now: Date, interval: TimeInterval) -> Bool {
        let elapsed = now.timeIntervalSince(previous)
        // A clock adjustment must not freeze a previously successful cache.
        return elapsed < 0 || elapsed >= interval
    }

    public static func selectedRangeNeedsRefresh(_ range: DateInterval, previousRange: DateInterval?,
                                                refreshedAt: Date, now: Date, force: Bool) -> Bool {
        if force || previousRange != range { return true }
        let liveShortRange = range.end > now && range.duration <= 172_800
        return isDue(since: refreshedAt, at: now, interval: liveShortRange ? 2 : historicalInterval)
    }
}
