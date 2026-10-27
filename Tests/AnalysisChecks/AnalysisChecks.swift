import Foundation
import KeyTrailCore

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message: message) } }
func calendar(_ zone: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ sec: Int, _ c: Calendar) -> Date { c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: sec))! }
func date(_ y: Int, _ m: Int, _ d: Int, _ c: Calendar) -> Date { date(y, m, d, 12, 0, 0, c) }
func buckets(_ segments: [RhythmSegment], recorded: Set<Int>? = nil, active: Int = 60) -> [MinuteBucket] {
    segments.map { segment in
        var summary = ActivitySummary()
        if recorded == nil || recorded!.contains(segment.day) {
            summary.minuteCount = 1; summary.keyPresses = 10; summary.leftClicks = 2
            summary.totalActiveSeconds = active; summary.keyboardActiveSeconds = active; summary.mouseActiveSeconds = min(30, active)
            summary.peakKeysPerMinute = 10
        }
        return MinuteBucket(start: segment.start, summary: summary)
    }
}

@main struct AnalysisChecks {
    static func main() throws {
        let cn = calendar("Asia/Shanghai"), ny = calendar("America/New_York"), cl = calendar("America/Santiago")
        let leap = MonthlyRhythmPlan(anchor: date(2024, 2, 15, cn), observedThrough: date(2024, 3, 1, cn), calendar: cn)
        let normal = MonthlyRhythmPlan(anchor: date(2025, 2, 15, cn), observedThrough: date(2025, 3, 1, cn), calendar: cn)
        try check(leap.dates.count == 29 && leap.querySegments.count == 29 && normal.dates.count == 28, "February day counts wrong")
        try check(leap.querySegments.last?.end == leap.end, "Leap month does not end at March boundary")
        print("PASS Leap/non-leap February calendar and exact month boundary")

        let spring = MonthlyRhythmPlan(anchor: date(2026, 3, 10, ny), observedThrough: date(2026, 4, 1, ny), calendar: ny)
        let fall = MonthlyRhythmPlan(anchor: date(2026, 11, 10, ny), observedThrough: date(2026, 12, 1, ny), calendar: ny)
        try check(spring.querySegments.count == 31 && spring.querySegments.contains { $0.end.timeIntervalSince($0.start) == 23 * 3600 }, "Missing 23h day")
        try check(fall.querySegments.count == 30 && fall.querySegments.contains { $0.end.timeIntervalSince($0.start) == 25 * 3600 }, "Missing 25h day")
        print("PASS Monthly natural days preserve 23/25-hour DST days")

        let midnight = MonthlyRhythmPlan(anchor: date(2026, 9, 15, cl), observedThrough: date(2026, 10, 2, cl), calendar: cl)
        try check(midnight.querySegments.count == 30 && midnight.querySegments.last!.end == midnight.end, "Midnight DST includes next month")
        try check(midnight.querySegments[5].end == date(2026, 9, 7, 0, 0, 0, cl) && midnight.querySegments[6].start == date(2026, 9, 7, 0, 0, 0, cl), "Midnight DST causes persistent 01:00 drift")
        try check(zip(midnight.querySegments, midnight.querySegments.dropFirst()).allSatisfy { $0.end == $1.start }, "Month intervals have gaps/overlaps")
        print("PASS Midnight DST stays contiguous and excludes October data")

        let now = date(2026, 10, 25, 11, 35, 17, cn)
        let partial = MonthlyRhythmPlan(anchor: now, observedThrough: now, calendar: cn)
        let month = try MonthlyRhythm(plan: partial, buckets: buckets(partial.querySegments), isDemo: true)
        try check(partial.querySegments.count == 25 && partial.querySegments.last!.end == now && month.days.filter(\.isFuture).count == 6, "Partial month counts future dates")
        try check(month.summary.keyPresses == 250 && month.recordedDayCount == 25 && month.report.contains("【演示数据】") && month.report.contains("本月未结束"), "Monthly report totals or demo labels wrong")
        print("PASS Partial month, six future days, exact totals and demo report")

        let future = MonthlyRhythmPlan(anchor: date(2026, 12, 10, cn), observedThrough: now, calendar: cn)
        let futureValue = try MonthlyRhythm(plan: future, buckets: [])
        let empty = try MonthlyRhythm(plan: leap, buckets: buckets(leap.querySegments, recorded: []))
        try check(future.querySegments.isEmpty && futureValue.days.allSatisfy(\.isFuture) && futureValue.report.contains("尚未开始"), "Future month presented as recorded zero")
        try check(empty.recordedDayCount == 0 && empty.report.contains("无统计记录不等于没有活动"), "Empty month misrepresented")
        print("PASS Future and empty months keep distinct semantics")

        var rejected = false
        do { _ = try MonthlyRhythm(plan: leap, buckets: []) } catch { rejected = true }
        try check(rejected, "Mismatched month response accepted")
        print("PASS Monthly response count mismatch rejected")

        let daily = DailyComparisonPlan(anchor: now, now: now, calendar: cn)
        try check(daily.querySegments.count == 8 && daily.excludedClockDays == 0 && daily.querySegments.allSatisfy { abs($0.end.timeIntervalSince($0.start) - daily.end.timeIntervalSince(daily.start)) < 0.01 }, "Equal-clock daily ranges differ")
        var sample = buckets(daily.querySegments, recorded: [0, 2, 5, 7])
        sample[0].summary.totalActiveSeconds = 60; sample[2].summary.totalActiveSeconds = 120; sample[5].summary.totalActiveSeconds = 180; sample[7].summary.totalActiveSeconds = 300
        let comparison = try DailyComparison(plan: daily, buckets: sample)
        try check(comparison.sampleCount == 3 && comparison.baselineActiveSeconds == 120 && comparison.differenceSeconds == 180, "Missing days diluted baseline or wrong difference")
        print("PASS Three recorded historical days form correct mean; missing days excluded")

        let insufficient = try DailyComparison(plan: daily, buckets: buckets(daily.querySegments, recorded: [0, 1, 7]))
        let noCurrent = try DailyComparison(plan: daily, buckets: buckets(daily.querySegments, recorded: Set(0..<7)))
        try check(insufficient.sampleCount == 2 && insufficient.baselineActiveSeconds == nil && insufficient.differenceSeconds == nil, "Insufficient samples yielded baseline")
        try check(noCurrent.sampleCount == 7 && noCurrent.baselineActiveSeconds == nil && noCurrent.headline.contains("暂无统计记录"), "Current missing data treated as lower activity")
        print("PASS Insufficient baseline and unrecorded current day refuse comparison")

        let zero = try DailyComparison(plan: daily, buckets: buckets(daily.querySegments, recorded: [0, 1, 2, 7], active: 0))
        try check(zero.baselineActiveSeconds == 0 && zero.differenceSeconds == 0 && zero.headline.contains("接近"), "Recorded zero-second sample mishandled")
        print("PASS Valid zero-second baseline stays finite without percentage division")

        let dst = DailyComparisonPlan(anchor: date(2026, 3, 9, ny), now: date(2026, 3, 10, ny), calendar: ny)
        try check(dst.excludedClockDays == 1 && dst.querySegments.count == 7, "23-hour history compared to 24-hour selected day")
        let missingTwo = DailyComparisonPlan(anchor: date(2026, 3, 9, 2, 0, 0, ny), now: date(2026, 3, 9, 2, 0, 0, ny), calendar: ny)
        try check(missingTwo.excludedClockDays == 1 && !missingTwo.querySegments.contains { ny.isDate($0.start, inSameDayAs: date(2026, 3, 8, ny)) }, "Missing 02:00 silently shifted to 03:00 baseline")
        print("PASS DST duration mismatch and nonexistent local cutoff excluded")

        let midnightDay = DailyComparisonPlan(anchor: date(2026, 9, 6, cl), now: date(2026, 9, 7, cl), calendar: cl)
        try check(midnightDay.end == date(2026, 9, 7, 0, 0, 0, cl) && midnightDay.end.timeIntervalSince(midnightDay.start) == 23 * 3600 && midnightDay.excludedClockDays == 7, "Midnight DST comparison shifted day end or history starts")
        let futureDay = DailyComparisonPlan(anchor: date(2026, 12, 1, cn), now: now, calendar: cn)
        let futureComparison = try DailyComparison(plan: futureDay, buckets: [])
        try check(futureDay.querySegments.isEmpty && futureComparison.baselineActiveSeconds == nil && futureComparison.headline.contains("尚未开始"), "Future day compared as zero")
        print("PASS Midnight DST current-day bounds and future comparison state")

        var summary = ActivitySummary(); summary.keyboardActiveSeconds = 70; summary.mouseActiveSeconds = 50; summary.totalActiveSeconds = 100
        let mix = InteractionMix(summary: summary)!
        try check(mix.keyboardOnlySeconds == 50 && mix.mouseOnlySeconds == 30 && mix.overlapSeconds == 20 && mix.totalSeconds == 100, "Window union arithmetic wrong")
        let emptyMix = InteractionMix(summary: ActivitySummary())
        summary.totalActiveSeconds = 60
        try check(InteractionMix(summary: summary) == nil && emptyMix?.totalSeconds == 0, "Invalid/empty mix not handled")
        summary.keyboardActiveSeconds = Int.max; summary.mouseActiveSeconds = 1; summary.totalActiveSeconds = Int.max
        try check(InteractionMix(summary: summary) == nil, "Overflow not rejected")
        print("PASS Window mix conservation, empty case, invalid union and overflow")
        print("Passed 12 monthly/comparison/mix checks")
    }
}
