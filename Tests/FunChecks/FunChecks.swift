import Foundation
import KeyTrailCore

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}
func calendar(_ zone: String) -> Calendar {
    var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!
    return value
}
func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, in value: Calendar) -> Date {
    value.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}
func bucket(_ time: Date, keys: Int, records: Int = 1) -> MinuteBucket {
    var value = ActivitySummary(); value.keyPresses = keys; value.minuteCount = records
    return MinuteBucket(start: time, summary: value)
}
func metrics(_ summary: ActivitySummary = ActivitySummary(), lifetime: Int = 0, timing: TimingInsights? = nil, history: [MinuteBucket] = [], settings: FunSettings = FunSettings(), now: Date, calendar: Calendar) -> FunMetrics {
    FunMetrics(summary: summary, lifetimeKeyPresses: lifetime, timing: timing,
               selectedInterval: calendar.dateInterval(of: .day, for: now)!, recentHistory: history, settings: settings, now: now, calendar: calendar)
}

@main struct FunChecks {
    static func main() throws {
        let cn = calendar("Asia/Shanghai"), now = date(2026, 10, 25, 13, 30, in: cn)
        try check(metrics(now: now, calendar: cn).energyScore == nil, "Empty data received an energy score")
        var scroll = ActivitySummary(); scroll.scrollUnits = 12; scroll.minuteCount = 1
        try check(metrics(scroll, now: now, calendar: cn).energyScore == nil, "Unweighted scroll falsely yielded energy")
        print("PASS Empty and unweighted data have no fabricated energy score")

        var one = ActivitySummary(); one.keyPresses = 1
        var thousand = one; thousand.keyPresses = 1000
        var click = ActivitySummary(); click.leftClicks = 250
        var pointer = ActivitySummary(); pointer.mouseDistancePoints = 100_000
        try check(metrics(one, now: now, calendar: cn).energyScore == 1 && metrics(thousand, now: now, calendar: cn).energyScore == 64, "Energy formula does not match canonical fixtures")
        try check(metrics(click, now: now, calendar: cn).energyScore == 64 && metrics(pointer, now: now, calendar: cn).energyScore == 64, "Energy weights are inconsistent")
        print("PASS Energy fixtures: one key=1; 1000 keys/250 clicks/100000 points each=64")

        var last = 0
        for count in [1, 10, 100, 1000, 10_000, 100_000, Int.max] {
            var value = ActivitySummary(); value.keyPresses = count; value.leftClicks = count; value.rightClicks = count; value.middleClicks = count
            let score = metrics(value, now: now, calendar: cn).energyScore!
            try check((1...100).contains(score) && score >= last, "Energy was unbounded, overflowed, or decreased")
            last = score
        }
        try check(last == 100, "High-volume score did not saturate")
        print("PASS Energy monotonicity, saturation and huge count overflow protection")

        var bad = ActivitySummary(); bad.keyPresses = -1
        try check(metrics(bad, now: now, calendar: cn).energyScore == nil, "Negative counts yielded energy")
        bad.keyPresses = 1; bad.mouseDistancePoints = .infinity
        try check(metrics(bad, now: now, calendar: cn).energyScore == nil, "Infinite cursor distance yielded energy")
        bad.mouseDistancePoints = .nan
        try check(metrics(bad, now: now, calendar: cn).energyScore == nil, "NaN cursor distance yielded energy")
        print("PASS Invalid energy inputs never become plausible scores")

        let defaults = FunSettings()
        try check(defaults.metersPerPress == 0.01 && defaults.referenceDistanceMeters == 40_075_000, "Default fictional mapping changed")
        let mapped = metrics(thousand, now: now, calendar: cn)
        try check(mapped.mappedDistanceMeters == 10 && mapped.routeCompletions == 10 / 40_075_000.0, "Fictional distance uses something other than key count")
        var settings = defaults; settings.reference = .beijingGuangzhou
        try check(settings.referenceDistanceMeters == 2_300_000, "Rail game constant changed")
        settings.reference = .custom; settings.customDistanceMeters = 5
        try check(metrics(thousand, settings: settings, now: now, calendar: cn).routeCompletions == 2, "Route progress was incorrectly capped at one lap")
        print("PASS Fictional scale, preset references and multiple custom laps")

        settings.metersPerPress = 0
        try check(settings.validationError != nil && metrics(thousand, settings: settings, now: now, calendar: cn).mappedDistanceMeters == nil, "Zero fictional scale accepted")
        for value in [-1.0, Double.infinity, Double.nan, 1001] {
            settings.metersPerPress = value; try check(settings.validationError != nil, "Invalid fictional scale accepted")
        }
        settings = defaults; settings.customDistanceMeters = 0
        try check(settings.validationError != nil, "Zero custom reference accepted")
        settings.customDistanceMeters = .nan
        try check(settings.validationError != nil, "NaN reference accepted")
        settings = defaults
        let roundTrip = try JSONDecoder().decode(FunSettings.self, from: JSONEncoder().encode(settings))
        try check(roundTrip == defaults, "Settings Codable round trip changed values")
        print("PASS Settings validation and persistence-compatible Codable round trip")

        let old = metrics(thousand, timing: TimingInsights(), now: now, calendar: cn)
        try check(old.bpm == nil && old.burstPeak == nil && old.intervalSampleCount == 0, "Old aggregate data fabricated timing")
        let rhythm = TimingInsights(intervalCount: 4, intervalSumMs: 2000, bpm: 120, burstPeak: 5, burstPeakAt: now.addingTimeInterval(23), measuredMinutes: 1)
        let timed = metrics(one, timing: rhythm, now: now, calendar: cn)
        try check(timed.bpm == 120 && timed.intervalSampleCount == 4 && timed.burstPeak == 5 && timed.timingMeasuredMinutes == 1, "Timing was computed from selected key count instead of intervals")
        try check(timed.burstPeakMinute?.timeIntervalSince1970 == floor(now.timeIntervalSince1970 / 60) * 60, "Burst display leaked sub-minute precision")
        print("PASS Interval BPM independent of count/min and burst time only to minute precision")

        for mean in [30.0, 2_000.0] {
            let value = TimingInsights(intervalCount: 1, intervalSumMs: mean, bpm: 60_000 / mean)
            try check(metrics(timing: value, now: now, calendar: cn).bpm != nil, "Valid interval boundary rejected")
        }
        for mean in [29.0, 2001.0] {
            let value = TimingInsights(intervalCount: 1, intervalSumMs: mean, bpm: 60_000 / mean)
            try check(metrics(timing: value, now: now, calendar: cn).bpm == nil, "Invalid interval boundary accepted")
        }
        var mismatch = rhythm; mismatch.bpm = 999
        try check(metrics(timing: mismatch, now: now, calendar: cn).bpm == nil, "Contradictory reported BPM accepted")
        mismatch = rhythm; mismatch.intervalCount = -1
        try check(metrics(timing: mismatch, now: now, calendar: cn).bpm == nil, "Negative interval count accepted")
        let interval = cn.dateInterval(of: .day, for: now)!
        mismatch = rhythm; mismatch.burstPeakAt = interval.end
        try check(metrics(timing: mismatch, now: now, calendar: cn).burstPeak == nil, "Half-open range accepted burst at its end")
        print("PASS BPM bounds, contradictory evidence and half-open burst boundary")

        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(TimingInsights.self, from: encoder.encode(rhythm))
        try check(decoded.burstPeakAt == rhythm.burstPeakAt && decoded.intervalSumMs == 2000, "Runtime JSON timing contract changed")
        print("PASS Timing JSON seconds-since-epoch contract")

        let recent = [bucket(date(2026, 10, 22, in: cn), keys: 60), bucket(date(2026, 10, 23, in: cn), keys: 120), bucket(date(2026, 10, 24, in: cn), keys: 180)]
        let wear = metrics(lifetime: 9_999_000, history: recent, now: now, calendar: cn)
        try check(wear.wearSampleDayCount == 3 && wear.wearAveragePressesPerRecordedDay == 120 && abs(wear.wearRemainingRecordedDays! - 1000 / 120.0) < 0.00001, "Wear sample mean or threshold projection wrong")
        let insufficient = metrics(lifetime: 10, history: Array(recent.prefix(2)), now: now, calendar: cn)
        try check(insufficient.wearSampleDayCount == 2 && insufficient.wearRemainingRecordedDays == nil, "Fewer than three days yielded prediction")
        print("PASS Three distinct recorded dates required for conditional wear estimate")

        let withZero = [recent[0], recent[1], bucket(date(2026, 10, 24, in: cn), keys: 0)]
        let zeroDay = metrics(lifetime: 100, history: withZero, now: now, calendar: cn)
        try check(zeroDay.wearSampleDayCount == 3 && zeroDay.wearAveragePressesPerRecordedDay == 60, "Recorded zero-key day disappeared from mean")
        let noKeys = recent.map { bucket($0.start, keys: 0) }
        try check(metrics(history: noKeys, now: now, calendar: cn).wearRemainingRecordedDays == nil, "Zero average yielded a fabricated estimate")
        print("PASS Recorded zero-key days retained; zero average never predicts")

        let beginning = wear.wearSampleInterval.start
        let outside = recent + [bucket(beginning.addingTimeInterval(-60), keys: 1_000_000), bucket(cn.startOfDay(for: now), keys: 1_000_000), bucket(beginning, keys: 120)]
        let clipped = metrics(history: outside, now: now, calendar: cn)
        try check(clipped.wearSampleDayCount == 4 && clipped.wearAveragePressesPerRecordedDay == 120, "30-day half-open sample range included old/current partial day or lost its start")
        let duplicatedDate = metrics(history: [recent[0], bucket(recent[0].start.addingTimeInterval(60), keys: 30), recent[1]], now: now, calendar: cn)
        try check(duplicatedDate.wearSampleDayCount == 2 && duplicatedDate.wearRemainingRecordedDays == nil, "Minute buckets counted as distinct sample days")
        print("PASS Thirty completed local dates and distinct-day aggregation")

        let ny = calendar("America/New_York"), afterSpring = date(2026, 3, 10, in: ny)
        let springHistory = [bucket(date(2026, 3, 7, 23, 30, in: ny), keys: 60), bucket(date(2026, 3, 8, 0, 30, in: ny), keys: 120), bucket(date(2026, 3, 9, 0, 30, in: ny), keys: 180)]
        let dst = metrics(history: springHistory, now: afterSpring, calendar: ny)
        try check(dst.wearSampleDayCount == 3 && dst.wearAveragePressesPerRecordedDay == 120, "Local dates were merged by UTC date")
        try check(dst.wearSampleInterval.duration == 30 * 86_400 - 3600, "Thirty local dates were treated as fixed UTC days")
        print("PASS Local sample dates and DST-sensitive thirty-day window")

        let cl = calendar("America/Santiago"), midnight = date(2026, 9, 6, in: cl)
        let midnightSample = metrics(history: [], now: midnight, calendar: cl)
        try check(cl.component(.hour, from: midnightSample.wearSampleInterval.end) == 1 && cl.component(.hour, from: midnightSample.wearSampleInterval.start) == 0, "Midnight DST drifted the historical start from 00:00 to 01:00")
        print("PASS Midnight DST normalizes the thirty-day historical start")

        let perKey = FunMetrics(summary: thousand, lifetimeKeyPresses: 9_999_100, timing: nil, selectedInterval: cn.dateInterval(of: .day, for: now)!, recentHistory: recent, settings: defaults, lifetimeKeyCounts: ["A": 9_999_000, "B": 100], recentKeyCounts: ["A": 300, "B": 30], now: now, calendar: cn)
        try check(perKey.keyWear.map(\.key) == ["A", "B"] && perKey.keyWear[0].sampleDayCount == 3 && perKey.keyWear[0].averagePressesPerRecordedDay == 100 && perKey.keyWear[0].remainingRecordedDays == 10, "Per-key wear used total keyboard count or wrong histogram mean")
        let noHistogram = FunMetrics(summary: thousand, lifetimeKeyPresses: 10, timing: nil, selectedInterval: cn.dateInterval(of: .day, for: now)!, recentHistory: recent, settings: defaults, lifetimeKeyCounts: ["A": 10], now: now, calendar: cn)
        try check(noHistogram.keyWear[0].remainingRecordedDays == nil && noHistogram.keyWear[0].averagePressesPerRecordedDay == nil, "Per-key history was guessed from total-count buckets")
        let shortPerKey = FunMetrics(summary: thousand, lifetimeKeyPresses: 10, timing: nil, selectedInterval: cn.dateInterval(of: .day, for: now)!, recentHistory: Array(recent.prefix(2)), settings: defaults, lifetimeKeyCounts: ["A": 10], recentKeyCounts: ["A": 300], now: now, calendar: cn)
        try check(shortPerKey.keyWear[0].remainingRecordedDays == nil, "Per-key estimate ignored the three-day evidence gate")
        print("PASS Per-key cumulative/histogram evidence and the three-day gate")

        let ranks = Dictionary(uniqueKeysWithValues: (0..<12).map { ("K\($0)", 100) })
        let topTen = FunMetrics(summary: thousand, lifetimeKeyPresses: 1_200, timing: nil, selectedInterval: cn.dateInterval(of: .day, for: now)!, recentHistory: recent, settings: defaults, lifetimeKeyCounts: ranks, recentKeyCounts: ranks, now: now, calendar: cn)
        try check(topTen.keyWear.count == 10 && topTen.keyWear.map(\.key) == ranks.keys.sorted().prefix(10).map { $0 }, "Per-key Top10 was unstable or exceeded ten entries")
        print("PASS Per-key Top10 rank is bounded and deterministic for ties")

        let reached = metrics(lifetime: Int.max, history: recent, now: now, calendar: cn)
        try check(reached.wearRemainingRecordedDays == 0 && reached.wearCumulativePresses == Int.max, "Reached threshold overflowed or yielded negative days")
        print("PASS Reached threshold and huge cumulative count remain safe")

        for (points, count) in [(99_999.0, 0), (100_000.0, 1), (500_000.0, 2), (1_000_000.0, 3), (5_000_000.0, 4)] {
            let badges = FunMetrics(summary: ActivitySummary(), lifetimeKeyPresses: 0, timing: nil, selectedInterval: interval, recentHistory: [], settings: defaults, lifetimeMouseDistancePoints: points, now: now, calendar: cn)
            try check(badges.cursorBadges.count == 4 && badges.cursorBadges.filter(\.achieved).count == count && badges.lifetimeMouseDistancePoints == points, "Cursor badge threshold used fictional distance or wrong comparison")
            try check(badges.cursorBadges.map(\.thresholdPoints) == [100_000, 500_000, 1_000_000, 5_000_000], "Cursor display-point thresholds changed")
        }
        print("PASS Cursor badges use actual cumulative display-point threshold boundaries")

        let noCursor = metrics(thousand, now: now, calendar: cn)
        let badCursor = FunMetrics(summary: thousand, lifetimeKeyPresses: 0, timing: nil, selectedInterval: interval, recentHistory: [], settings: defaults, lifetimeMouseDistancePoints: .nan, now: now, calendar: cn)
        try check(noCursor.cursorBadges.isEmpty && noCursor.lifetimeMouseDistancePoints == nil && badCursor.cursorBadges.isEmpty, "Unknown or invalid cursor distance was assessed as zero")
        print("PASS Unknown cursor totals never fabricate badge eligibility")

        var reportSettings = defaults; reportSettings.reference = .custom; reportSettings.customDistanceMeters = 5
        let reportMetrics = FunMetrics(summary: thousand, lifetimeKeyPresses: 9_999_100, timing: rhythm, selectedInterval: interval, recentHistory: recent, settings: reportSettings, lifetimeMouseDistancePoints: 500_000, lifetimeKeyCounts: ["A": 9_999_000], recentKeyCounts: ["A": 300], now: now, calendar: cn)
        reportSettings.metersPerPress = 100
        let appendix = reportMetrics.reportAppendix(calendar: cn)
        try check(appendix.contains("操作能量：64/100") && appendix.contains("10.00 游戏米") && appendix.contains("0.010000 米") && appendix.contains("间隔 BPM：120.0") && appendix.contains("最高连击：5 次"), "Report appendix did not preserve selected metrics and frozen settings")
        try check(appendix.contains("五十万显示点") && appendix.contains("累计 Top10") && appendix.contains("A：累计9999000次") && appendix.contains("还需约10.0个有记录日") && appendix.contains("生成时刻的累计/近期参照") && appendix.contains("不是单键耐久"), "Appendix omitted wear evidence or interpreted cumulative data as period-only/hardware life")
        print("PASS Frozen report appendix covers energy, mapping, BPM, burst, cursor badges and per-key wear")

        let emptyAppendix = metrics(now: now, calendar: cn).reportAppendix(calendar: cn)
        try check(emptyAppendix.contains("操作能量：无可加权计数") && emptyAppendix.contains("间隔 BPM：不适用") && emptyAppendix.contains("最高连击：无该范围") && emptyAppendix.contains("不足 3") && emptyAppendix.contains("缺少累计按键直方图"), "Missing report evidence became plausible metric values")
        let futureInterval = cn.dateInterval(of: .day, for: cn.date(byAdding: .day, value: 1, to: now)!)!
        let futureAppendix = FunMetrics(summary: thousand, lifetimeKeyPresses: 1000, timing: rhythm, selectedInterval: futureInterval, recentHistory: [], settings: defaults, now: now, calendar: cn).reportAppendix(calendar: cn)
        try check(futureAppendix.contains("不把未来时段记为零活动") && !futureAppendix.contains("操作能量：64/100") && !futureAppendix.contains("游戏旅程：10.00"), "Future period reported numeric activity")
        print("PASS Report missing-data and future-period states do not invent evidence")

        var tiny = defaults; tiny.reference = .custom; tiny.customDistanceMeters = .leastNonzeroMagnitude
        let overflowRatio = metrics(thousand, settings: tiny, now: now, calendar: cn)
        try check(overflowRatio.mappedDistanceMeters == 10 && overflowRatio.routeCompletions == nil && !overflowRatio.reportAppendix(calendar: cn).contains("inf"), "Tiny finite route produced an infinite result")
        print("PASS Finite but tiny custom route never yields an infinite derived ratio")

        let lordHowe = calendar("Australia/Lord_Howe"), afterHalfHour = date(2026, 10, 8, in: lordHowe)
        let dailyRanges = FunMetrics.historyRanges(now: afterHalfHour, calendar: lordHowe)
        try check(dailyRanges.count == 30 && dailyRanges.last?.end == lordHowe.startOfDay(for: afterHalfHour), "Wear history is not thirty completed local dates")
        try check(dailyRanges.allSatisfy { $0.start == lordHowe.startOfDay(for: $0.start) && $0.end == lordHowe.dateInterval(of: .day, for: $0.start)!.end } && zip(dailyRanges, dailyRanges.dropFirst()).allSatisfy { $0.end == $1.start }, "Wear history gaps/overlaps or drifts across local midnight")
        try check(dailyRanges.contains { $0.duration == 23.5 * 3600 }, "Lord Howe half-hour DST day was forced to 24 hours")
        let twoLocalDates = [date(2026, 10, 5, 0, 5, in: lordHowe), date(2026, 10, 5, 23, 55, in: lordHowe), date(2026, 10, 6, 23, 55, in: lordHowe)]
        let dailySummaries = dailyRanges.map { range -> MinuteBucket in
            let count = twoLocalDates.filter { $0 >= range.start && $0 < range.end }.count
            return bucket(range.start, keys: count, records: count)
        }
        let halfHourWear = metrics(history: dailySummaries, now: afterHalfHour, calendar: lordHowe)
        try check(halfHourWear.wearSampleDayCount == 2 && halfHourWear.wearAveragePressesPerRecordedDay == 1.5 && halfHourWear.wearRemainingRecordedDays == nil, "Two local recorded dates were incorrectly promoted to three after half-hour DST")
        print("PASS Natural-day history summaries prevent Lord Howe two-day samples becoming three")
        print("Passed 23 fun metric checks (pure aggregates; no input monitoring or uploads)")
    }
}
