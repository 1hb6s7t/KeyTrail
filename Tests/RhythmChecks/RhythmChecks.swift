import Foundation
import KeyTrailCore

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}
func calendar(_ zone: String) -> Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!; value.firstWeekday = 1
    return value
}
func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0, in cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}
func fixture(_ plan: WeeklyRhythmPlan) -> [MinuteBucket] {
    plan.querySegments.map { span in
        var summary = ActivitySummary()
        summary.keyPresses = 10; summary.leftClicks = 2; summary.rightClicks = 1
        summary.totalActiveSeconds = Int(span.end.timeIntervalSince(span.start))
        summary.keyboardActiveSeconds = summary.totalActiveSeconds; summary.mouseActiveSeconds = 10
        summary.mouseDistancePoints = 100; summary.minuteCount = 1; summary.peakKeysPerMinute = 10
        return MinuteBucket(start: span.start, summary: summary)
    }
}

@main struct RhythmChecks {
    static func main() throws {
        let cn = calendar("Asia/Shanghai"), ny = calendar("America/New_York"), lh = calendar("Australia/Lord_Howe")
        let ordinary = WeeklyRhythmPlan(anchor: date(2026, 10, 25, in: cn), observedThrough: date(2026, 10, 26, in: cn), calendar: cn)
        try check(ordinary.fullSegments.count == 168 && ordinary.weekEnd.timeIntervalSince(ordinary.weekStart) == 604800, "Ordinary week did not contain 168 hours")
        try check(cn.component(.weekday, from: ordinary.weekStart) == 2 && cn.component(.hour, from: ordinary.weekStart) == 0, "Week was not Monday local midnight despite Sunday-first calendar")
        print("PASS Monday-based local week and 168 contiguous hour ranges")

        let spring = WeeklyRhythmPlan(anchor: date(2026, 3, 8, in: ny), observedThrough: date(2026, 3, 9, in: ny), calendar: ny)
        let springResult = try WeeklyRhythm(plan: spring, buckets: fixture(spring))
        try check(spring.fullSegments.count == 167 && springResult.days[6].hours[2].isMissingClockHour, "Spring missing clock hour not marked")
        try check(springResult.summary.totalActiveSeconds == 167 * 3600, "Spring DST invented an extra hour")
        print("PASS Spring DST skips local 02:00 without invented activity")

        let fall = WeeklyRhythmPlan(anchor: date(2026, 11, 1, in: ny), observedThrough: date(2026, 11, 2, in: ny), calendar: ny)
        let fallResult = try WeeklyRhythm(plan: fall, buckets: fixture(fall))
        try check(fall.fullSegments.count == 168 && fallResult.days[6].hours[1].activeSeconds == 7200 && fallResult.summary.totalActiveSeconds == 169 * 3600, "Fall repeated hour was dropped or misplaced")
        print("PASS Fall DST merges both occurrences while preserving 169 elapsed hours")

        let half = WeeklyRhythmPlan(anchor: date(2026, 10, 4, in: lh), observedThrough: date(2026, 10, 5, in: lh), calendar: lh)
        let halfResult = try WeeklyRhythm(plan: half, buckets: fixture(half))
        try check(halfResult.days[6].hours[2].observedSeconds == 1800 && !halfResult.days[6].hours[2].isMissingClockHour && halfResult.summary.totalActiveSeconds == 167 * 3600 + 1800, "Half-hour DST mixed local hour cells")
        print("PASS Half-hour DST retains the 30-minute local hour")

        let ktm = calendar("Asia/Kathmandu")
        let offset = WeeklyRhythmPlan(anchor: date(2026, 10, 25, in: ktm), observedThrough: date(2026, 10, 26, in: ktm), calendar: ktm)
        try check(offset.fullSegments.allSatisfy { $0.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 && ktm.component(.minute, from: $0.start) == 0 }, "Quarter-hour UTC offset produced shifted local slots")
        print("PASS UTC+05:45 offset retains civil-hour boundaries")

        let tehran = calendar("Asia/Tehran")
        let midnight = WeeklyRhythmPlan(anchor: date(2021, 3, 25, in: tehran), observedThrough: date(2021, 3, 30, in: tehran), calendar: tehran)
        let midnightResult = try WeeklyRhythm(plan: midnight, buckets: fixture(midnight))
        try check(midnight.weekStart == date(2021, 3, 22, 1, in: tehran) && midnight.weekEnd == date(2021, 3, 29, 0, in: tehran), "Monday midnight DST drifted beyond the local week boundary")
        try check(midnight.weekEnd.timeIntervalSince(midnight.weekStart) == 167 * 3600 && midnight.fullSegments.count == 167 && midnightResult.summary.totalActiveSeconds == 167 * 3600, "Monday midnight DST invented an extra hour")
        try check(midnight.fullSegments.first?.start == midnight.weekStart && midnight.fullSegments.last?.end == midnight.weekEnd && midnight.fullSegments.allSatisfy { $0.start >= midnight.weekStart && $0.end <= midnight.weekEnd }, "Monday midnight DST included next-week activity")
        try check(zip(midnight.fullSegments, midnight.fullSegments.dropFirst()).allSatisfy { $0.end == $1.start }, "Monday midnight DST week has gaps or overlaps")
        print("PASS Monday-midnight DST preserves 167 hours and the exact next-Monday cutoff")

        try check(midnightResult.days.count == 7 && Set(midnight.dayStarts).count == 7 && midnightResult.recordedDayCount == 7, "Monday midnight DST lost a calendar day row")
        for (index, day) in midnightResult.days.enumerated() {
            try check(day.id == index && day.date == tehran.startOfDay(for: day.date) && tehran.component(.day, from: day.date) == 22 + index && tehran.component(.weekday, from: day.date) == (index + 1) % 7 + 1, "Monday midnight DST shifted a day-row date or weekday")
            try check(day.hours.reduce(0) { $0 + $1.observedSeconds } == (index == 0 ? 23 : 24) * 3600, "Monday midnight DST placed another day's hours in this row")
            for hour in day.hours {
                let expected = index == 0 && hour.id == 0 ? 0 : 3600
                try check(hour.activeSeconds == expected && hour.observedSeconds == expected && hour.isMissingClockHour == (expected == 0) && (expected == 0 || !hour.isFuture), "Monday midnight DST assigned an hour to the wrong day")
            }
        }
        try check(midnight.fullSegments.allSatisfy { tehran.startOfDay(for: $0.start) == midnight.dayStarts[$0.day] && tehran.component(.hour, from: $0.start) == $0.hour }, "Monday midnight DST segment day/hour mapping is inconsistent")
        print("PASS Monday-midnight DST maps all seven normalized day rows and every hour correctly")

        let cutoff = date(2026, 10, 21, 10, 17, 23, in: cn)
        let partial = WeeklyRhythmPlan(anchor: cutoff, observedThrough: cutoff, calendar: cn)
        let partialResult = try WeeklyRhythm(plan: partial, buckets: fixture(partial))
        try check(partial.querySegments.last?.end == cutoff && partialResult.days[2].hours[10].observedSeconds == 1043 && partialResult.days[2].hours[11].isFuture, "Partial week counted future seconds")
        print("PASS Current partial hour clips at observed-through and marks future cells")

        let future = WeeklyRhythmPlan(anchor: date(2026, 11, 4, in: cn), observedThrough: cutoff, calendar: cn)
        let futureResult = try WeeklyRhythm(plan: future, buckets: [])
        try check(future.querySegments.isEmpty && futureResult.days.flatMap(\.hours).allSatisfy(\.isFuture) && futureResult.report.contains("尚未开始"), "Future week was presented as observed zero activity")
        let emptyResult = try WeeklyRhythm(plan: ordinary, buckets: ordinary.querySegments.map { MinuteBucket(start: $0.start, summary: ActivitySummary()) })
        try check(emptyResult.recordedDayCount == 0 && emptyResult.report.contains("无统计记录不等于没有活动"), "Empty data implies inactivity")
        print("PASS Future and no-records weeks have distinct honest report states")

        let report = try WeeklyRhythm(plan: ordinary, buckets: fixture(ordinary), isDemo: true)
        try check(report.summary.keyPresses == 1680 && report.summary.totalClicks == 504 && report.recordedDayCount == 7 && report.report.contains("【演示数据】") && report.report.contains("非物理距离") && report.report.contains("不代表工作效率"), "Report totals or scope labels incorrect")
        print("PASS Report totals, demo label, units, and interpretation limits")

        var rejected = false
        do {
            var wrong = fixture(ordinary); wrong[0].start = wrong[0].start.addingTimeInterval(60)
            _ = try WeeklyRhythm(plan: ordinary, buckets: wrong)
        } catch { rejected = (error as NSError).domain == "KeyTrail.Rhythm" }
        try check(rejected, "Mismatched response timestamp accepted")
        print("PASS Mismatched timeline responses rejected")
        print("Passed 11 weekly rhythm checks")
    }
}
