import Foundation
import KeyTrailFloatingUI
import KeyTrailIPC

private struct Failure: Error { let message: String }
private func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(message: message) }
}
private func rejects(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw Failure(message: message)
}
private func calendar(_ zone: String) -> Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: zone)!
    return value
}
private func timestamp(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private func status(monitoring: Bool = true, paused: Bool = false, permission: Bool = true,
                    suspended: Bool = false, demo: Bool = false) -> RuntimeStatus {
    RuntimeStatus(monitoring: monitoring, paused: paused, permissionGranted: permission,
                  suspended: suspended, statusText: suspended ? "系统挂起" : "正在记录",
                  pid: 123, backend: "rust", isDemo: demo)
}
private func summary() -> [String: Any] {
    ["keyPresses": 120, "leftClicks": 12, "rightClicks": 4, "middleClicks": 2,
     "mouseDistancePoints": 12345.25, "totalActiveSeconds": 75,
     "keyboardActiveSeconds": 60, "mouseActiveSeconds": 35]
}

@main
struct FloatingChecks {
    static func main() throws {
        let cn = calendar("Asia/Shanghai")
        let now = timestamp("2026-10-26T14:27:12+08:00")
        let hour = try FloatingStatsRange(period: .currentHour, now: now, calendar: cn)
        let day = try FloatingStatsRange(period: .today, now: now, calendar: cn)
        try check(hour.start == timestamp("2026-10-26T14:00:00+08:00") && hour.end == now,
                  "Current hour is not the local half-open interval")
        try check(day.start == timestamp("2026-10-26T00:00:00+08:00") && day.end == now,
                  "Today does not start at local midnight")
        try check(hour.request["op"] as? String == "summary" && hour.request["end"] as? Double == now.timeIntervalSince1970,
                  "Read-only request changed operation or end boundary")
        let midnight = timestamp("2026-10-27T00:00:00+08:00")
        let empty = try FloatingStatsRange(period: .today, now: midnight, calendar: cn)
        try check(empty.start == midnight && empty.start == empty.end, "Midnight includes yesterday or invents future time")
        try rejects("Nonfinite time accepted") {
            _ = try FloatingStatsRange(period: .today, now: Date(timeIntervalSince1970: .nan), calendar: cn)
        }
        print("PASS Local current-hour/today half-open boundaries and midnight rollover")

        let la = calendar("America/Los_Angeles")
        let first = try FloatingStatsRange(period: .currentHour, now: timestamp("2026-11-01T01:30:00-07:00"), calendar: la)
        let second = try FloatingStatsRange(period: .currentHour, now: timestamp("2026-11-01T01:30:00-08:00"), calendar: la)
        try check(second.start.timeIntervalSince(first.start) == 3600 &&
                  first.end.timeIntervalSince(first.start) == 1800 && second.end.timeIntervalSince(second.start) == 1800,
                  "Repeated local hour is assigned to the wrong absolute hour")
        for (text, expected) in [("2026-03-08T23:30:00-07:00", 22.5 * 3600),
                                 ("2026-11-01T23:30:00-08:00", 24.5 * 3600)] {
            let range = try FloatingStatsRange(period: .today, now: timestamp(text), calendar: la)
            try check(range.end.timeIntervalSince(range.start) == expected, "DST day uses fixed 24-hour arithmetic")
        }
        let lordHowe = try FloatingStatsRange(period: .today,
                                              now: timestamp("2026-10-04T23:45:00+11:00"),
                                              calendar: calendar("Australia/Lord_Howe"))
        try check(lordHowe.end.timeIntervalSince(lordHowe.start) == 23.25 * 3600, "Half-hour DST day boundary drifted")
        print("PASS Spring/fall DST days, repeated hour and half-hour DST")

        let snapshot = try FloatingStatsSnapshot(summary: summary(), status: status(), range: hour, capturedAt: now)
        try check(snapshot.keyPresses == 120 && snapshot.totalClicks == 18 && snapshot.mouseDistancePoints == 12345.25,
                  "Stats fields or combined click total changed")
        try check(snapshot.totalActiveSeconds == 75, "Keyboard and mouse active times were added instead of using the deduplicated total")
        let encoded = try JSONSerialization.data(withJSONObject: summary())
        let json = try JSONSerialization.jsonObject(with: encoded)
        let decoded = try FloatingStatsSnapshot(summary: json, status: status(), range: hour, capturedAt: now)
        try check(decoded == snapshot, "JSON NSNumber bridge changed numeric fields")
        var zero = summary()
        for key in ["keyPresses", "leftClicks", "rightClicks", "middleClicks", "mouseDistancePoints", "totalActiveSeconds"] { zero[key] = 0 }
        let zeroSnapshot = try FloatingStatsSnapshot(summary: zero, status: status(), range: empty, capturedAt: midnight)
        try check(zeroSnapshot.totalClicks == 0 && zeroSnapshot.totalActiveSeconds == 0, "Valid zero stats rejected")
        print("PASS Strict JSON numeric parsing, combined clicks and deduplicated active time")

        for field in ["keyPresses", "leftClicks", "rightClicks", "middleClicks", "totalActiveSeconds"] {
            for bad: Any in [-1, 1.25, true, "12", NSNull()] {
                var object = summary(); object[field] = bad
                try rejects("Invalid integer field \(field) accepted") {
                    _ = try FloatingStatsSnapshot(summary: object, status: status(), range: hour, capturedAt: now)
                }
            }
            var missing = summary(); missing.removeValue(forKey: field)
            try rejects("Missing integer field \(field) became zero") {
                _ = try FloatingStatsSnapshot(summary: missing, status: status(), range: hour, capturedAt: now)
            }
        }
        for bad: Any in [-0.5, Double.nan, Double.infinity, true, "1.2", NSNull()] {
            var object = summary(); object["mouseDistancePoints"] = bad
            try rejects("Invalid cursor distance accepted") {
                _ = try FloatingStatsSnapshot(summary: object, status: status(), range: hour, capturedAt: now)
            }
        }
        var overflow = summary(); overflow["leftClicks"] = Int.max; overflow["rightClicks"] = 1
        try rejects("Combined clicks overflowed") {
            _ = try FloatingStatsSnapshot(summary: overflow, status: status(), range: hour, capturedAt: now)
        }
        try rejects("Invalid top-level response accepted") {
            _ = try FloatingStatsSnapshot(summary: [], status: status(), range: hour, capturedAt: now)
        }
        print("PASS Invalid/missing/nonfinite fields and click overflow fail without fabricated zeros")

        try check(FloatingStatsFormat.count(12345) == "12,345" && FloatingStatsFormat.count(-1) == "—", "Count format misleading")
        try check(FloatingStatsFormat.distance(12345.25) == "12,345 点" && FloatingStatsFormat.distance(.nan) == "—" &&
                  FloatingStatsFormat.distance(-1) == "—", "Distance is not explicitly display points")
        try check(FloatingStatsFormat.activity(0) == "0 秒" && FloatingStatsFormat.activity(59) == "59 秒" &&
                  FloatingStatsFormat.activity(75) == "1 分 15 秒" && FloatingStatsFormat.activity(3720) == "1 时 02 分" &&
                  FloatingStatsFormat.activity(-1) == "—", "Activity boundary formatting is incorrect")
        print("PASS Count, display-point distance and activity formatting")

        try check(snapshot.collector.isRecording && !FloatingCollectorStatus(status(paused: true)).isRecording &&
                  !FloatingCollectorStatus(status(permission: false)).isRecording &&
                  !FloatingCollectorStatus(status(suspended: true)).isRecording &&
                  !FloatingCollectorStatus(status(monitoring: false)).isRecording,
                  "Paused, unauthorized or suspended collector labeled recording")
        let demo = FloatingCollectorStatus(status(demo: true))
        try check(!demo.isRecording && demo.label.contains("演示数据"), "Demo status is not visible")
        try check(!snapshot.isStale(at: now.addingTimeInterval(10)) && snapshot.isStale(at: now.addingTimeInterval(11)) &&
                  snapshot.isStale(at: now.addingTimeInterval(-1)), "Stale or backwards-clock status handling failed")
        print("PASS Truthful collector/demo status, stale age and backwards clock handling")
    }
}
