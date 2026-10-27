import Foundation
import KeyTrailCore
import KeyTrailRuntime

extension RuntimeChecks {
    @MainActor static func checkHistoricalCacheRefresh(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_704_067_200)
        let range = DateInterval(start: base, duration: 120)
        do {
            let store = try ActivityStore(url: directory.appendingPathComponent("activity.sqlite"))
            try store.ingest([InputSample(timestamp: base, kind: .keyPress, keyLabel: "A")], observedThrough: base.addingTimeInterval(1))
            try store.endActivity(at: base.addingTimeInterval(1))
        }
        let runtime = try RuntimeController(isDemo: true, directory: directory)
        defer { runtime.shutdown() }
        let request: [String: Any] = ["op": "summary", "start": base.timeIntervalSince1970,
                                      "end": range.end.timeIntervalSince1970]
        func readCount() throws -> Int {
            let response = runtime.handle(request)
            guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any],
                  let count = result["keyPresses"] as? Int else { throw CheckFailure(message: "Historical summary unavailable") }
            return count
        }
        let cachedAt = base.addingTimeInterval(3600)
        var displayed = try readCount()
        try require(displayed == 1, "Historical fixture did not contain initial event")
        // An external deletion has no dashboard control callback to invalidate
        // its cache. Retention has the same lack of a dashboard callback.
        let deleted = runtime.handle(["op": "delete", "start": base.timeIntervalSince1970, "end": range.end.timeIntervalSince1970])
        try require(deleted["ok"] as? Bool == true, "External deletion failed")
        try require(!DashboardRefreshPolicy.selectedRangeNeedsRefresh(range, previousRange: range, refreshedAt: cachedAt,
            now: cachedAt.addingTimeInterval(2), force: false), "Historical selection polled at live cadence")
        if DashboardRefreshPolicy.selectedRangeNeedsRefresh(range, previousRange: range, refreshedAt: cachedAt,
            now: cachedAt.addingTimeInterval(30), force: false) { displayed = try readCount() }
        try require(displayed == 0, "Historical selection kept deleted activity past its refresh deadline")
        try require(DashboardRefreshPolicy.isDue(since: cachedAt, at: cachedAt.addingTimeInterval(30), interval: 30),
                    "Historical week/month insights cannot expire")
        try require(DashboardRefreshPolicy.selectedRangeNeedsRefresh(range, previousRange: range, refreshedAt: cachedAt,
            now: cachedAt.addingTimeInterval(-60), force: false), "Clock rollback freezes historical statistics")
        let live = DateInterval(start: cachedAt, duration: 3600)
        try require(DashboardRefreshPolicy.selectedRangeNeedsRefresh(live, previousRange: live, refreshedAt: cachedAt,
            now: cachedAt.addingTimeInterval(2), force: false), "Live short-range cadence regressed")
        try require(DashboardRefreshPolicy.selectedRangeNeedsRefresh(range, previousRange: range, refreshedAt: cachedAt,
            now: cachedAt, force: true), "Explicit refresh was throttled")
        try require(DashboardRefreshPolicy.selectedRangeNeedsRefresh(range, previousRange: live, refreshedAt: cachedAt,
            now: cachedAt, force: false), "Selection change was throttled")
        print("PASS Visible historical cache expires after external deletion; live, forced, changed-range and clock-reset refresh remain available")
    }
}
