import Foundation

public enum InsightPeriod: String, CaseIterable, Identifiable, Sendable {
    case week, month
    public var id: String { rawValue }
    public var title: String { self == .week ? "按周" : "按月" }
}

public struct InteractionMix: Sendable {
    public let keyboardOnlySeconds: Int
    public let mouseOnlySeconds: Int
    public let overlapSeconds: Int
    public let totalSeconds: Int

    public init?(summary: ActivitySummary) {
        let keyboard = summary.keyboardActiveSeconds, mouse = summary.mouseActiveSeconds, union = summary.totalActiveSeconds
        guard keyboard >= 0, mouse >= 0, union >= max(keyboard, mouse),
              keyboard <= Int.max - mouse, union <= keyboard + mouse else { return nil }
        overlapSeconds = keyboard + mouse - union
        keyboardOnlySeconds = union - mouse
        mouseOnlySeconds = union - keyboard
        totalSeconds = union
    }
}

public struct RhythmMonthDay: Identifiable, Sendable {
    public let id: Int
    public let date: Date
    public var summary: ActivitySummary
    public let isFuture: Bool
    public var hasRecords: Bool { summary.containsRecordedActivity }
}

public struct MonthlyRhythmPlan: Sendable {
    public let start: Date
    public let end: Date
    public let observedThrough: Date
    public let calendar: Calendar
    public let dates: [Date]
    public let querySegments: [RhythmSegment]

    public init(anchor: Date, observedThrough: Date = Date(), calendar: Calendar = .current) {
        let interval = calendar.dateInterval(of: .month, for: anchor)!
        start = interval.start; end = interval.end
        self.observedThrough = min(observedThrough, interval.end); self.calendar = calendar
        var dates: [Date] = [], segments: [RhythmSegment] = []
        var cursor = interval.start
        while cursor < interval.end {
            let next = min(interval.end, calendar.dateInterval(of: .day, for: cursor)!.end)
            if cursor < observedThrough {
                segments.append(RhythmSegment(start: cursor, end: min(next, observedThrough), day: dates.count, hour: 0))
            }
            dates.append(cursor); cursor = next
        }
        self.dates = dates; querySegments = segments
    }
}

public struct MonthlyRhythm: Sendable {
    public let start: Date
    public let end: Date
    public let observedThrough: Date
    public let days: [RhythmMonthDay]
    public let summary: ActivitySummary
    public let recordedDayCount: Int
    public let firstWeekdayOffset: Int
    public let title: String
    public let report: String

    public init(plan: MonthlyRhythmPlan, buckets: [MinuteBucket], isDemo: Bool = false) throws {
        try validateInsightResponse(buckets, segments: plan.querySegments)
        start = plan.start; end = plan.end; observedThrough = plan.observedThrough
        firstWeekdayOffset = (plan.calendar.component(.weekday, from: start) + 5) % 7
        var days = plan.dates.enumerated().map { index, date in
            RhythmMonthDay(id: index + 1, date: date, summary: ActivitySummary(), isFuture: date >= plan.observedThrough)
        }
        var total = ActivitySummary()
        for (bucket, segment) in zip(buckets, plan.querySegments) {
            days[segment.day].summary = bucket.summary
            total.mergeInsightSummary(bucket.summary)
        }
        self.days = days; summary = total
        recordedDayCount = days.filter(\.hasRecords).count
        let formatter = insightFormatter(calendar: plan.calendar, format: "yyyy 年 M 月")
        title = formatter.string(from: start)
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        var lines = [isDemo ? "键迹月报【演示数据】" : "键迹月报", title, "时区：\(plan.calendar.timeZone.identifier)"]
        if observedThrough <= start { lines.append("这个月尚未开始，暂无可汇总记录。") }
        else {
            lines.append("统计截至：\(formatter.string(from: observedThrough))\(observedThrough < end ? "（本月未结束）" : "（完整自然月区间）")")
            lines.append("有统计记录的日期：\(recordedDayCount) / \(days.count) 天。")
            lines.append("键盘敲击 \(total.keyPresses) 次；鼠标点击 \(total.totalClicks) 次。")
            lines.append("键鼠去重活跃时长：\(insightDuration(Double(total.totalActiveSeconds)))。")
            if let mix = InteractionMix(summary: total) {
                lines.append("仅键盘活动窗口 \(insightDuration(Double(mix.keyboardOnlySeconds)))，仅鼠标活动窗口 \(insightDuration(Double(mix.mouseOnlySeconds)))，重叠窗口 \(insightDuration(Double(mix.overlapSeconds)))。")
            }
            if let peak = days.filter({ $0.summary.totalActiveSeconds > 0 }).max(by: { $0.summary.totalActiveSeconds < $1.summary.totalActiveSeconds }) {
                formatter.dateFormat = "M 月 d 日"
                lines.append("记录活跃时长最多的一天：\(formatter.string(from: peak.date))，\(insightDuration(Double(peak.summary.totalActiveSeconds)))。")
            }
            if total.containsRecordedActivity {
                lines.append("自然分钟按键峰值：\(total.peakKeysPerMinute) 次/分。")
                lines.append("光标累计 \(Int(total.mouseDistancePoints.rounded())) pt（屏幕显示点，非物理距离）。")
            } else { lines.append("该月暂无统计记录。") }
        }
        lines.append("无统计记录不等于没有活动；未开始采集、暂停或应用离线都可能造成空白。")
        lines.append("活跃时长按输入后的 30 秒窗口去重；窗口重叠不代表真实同时操作。日历截止时间不代表连续采集覆盖。")
        lines.append("本月报在本机根据分钟汇总生成，不推断工作内容，也不代表工作效率。")
        report = lines.joined(separator: "\n")
    }
}

public struct DailyComparisonPlan: Sendable {
    public let start: Date
    public let end: Date
    public let calendar: Calendar
    /// Historical days oldest first, followed by the selected day (day == 7).
    public let querySegments: [RhythmSegment]
    public let excludedClockDays: Int
    public let isFuture: Bool

    public init(anchor: Date, now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        start = calendar.startOfDay(for: anchor)
        let fullEnd = calendar.dateInterval(of: .day, for: start)!.end
        end = max(start, min(fullEnd, now)); isFuture = now <= start
        guard end > start else { querySegments = []; excludedClockDays = 0; return }
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: end)
        let fullDay = end == fullEnd
        var segments: [RhythmSegment] = []
        var excluded = 0
        for i in 0..<7 {
            let previous = calendar.startOfDay(for: calendar.date(byAdding: .day, value: i - 7, to: start)!)
            let previousEnd: Date
            if fullDay { previousEnd = calendar.dateInterval(of: .day, for: previous)!.end }
            else {
                let wallTime = calendar.date(bySettingHour: components.hour!, minute: components.minute!, second: components.second!, of: previous, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)!
                let actual = calendar.dateComponents([.hour, .minute, .second], from: wallTime)
                guard calendar.isDate(wallTime, inSameDayAs: previous), actual.hour == components.hour, actual.minute == components.minute, actual.second == components.second else { excluded += 1; continue }
                previousEnd = wallTime.addingTimeInterval(Double(components.nanosecond ?? 0) / 1_000_000_000)
            }
            // Clock changes can make equal clock labels have unequal durations.
            // Exclude those samples rather than silently comparing 23/25-hour days.
            guard previous >= Date(timeIntervalSince1970: 0),
                  calendar.dateComponents([.hour, .minute, .second], from: previous) == calendar.dateComponents([.hour, .minute, .second], from: start),
                  abs(previousEnd.timeIntervalSince(previous) - end.timeIntervalSince(start)) < 0.01 else { excluded += 1; continue }
            segments.append(RhythmSegment(start: previous, end: previousEnd, day: i, hour: 0))
        }
        segments.append(RhythmSegment(start: start, end: end, day: 7, hour: 0))
        querySegments = segments; excludedClockDays = excluded
    }
}

public struct DailyComparison: Sendable {
    public let title: String
    public let headline: String
    public let detail: String
    public let currentActiveSeconds: Int
    public let baselineActiveSeconds: Double?
    public let differenceSeconds: Double?
    public let sampleCount: Int

    public init(plan: DailyComparisonPlan, buckets: [MinuteBucket]) throws {
        try validateInsightResponse(buckets, segments: plan.querySegments)
        let current = zip(buckets, plan.querySegments).first(where: { $0.1.day == 7 })?.0.summary ?? ActivitySummary()
        let samples = zip(buckets, plan.querySegments).filter { $0.1.day != 7 && $0.0.summary.containsRecordedActivity }.map { $0.0.summary }
        currentActiveSeconds = current.totalActiveSeconds; sampleCount = samples.count
        let formatter = insightFormatter(calendar: plan.calendar, format: "M 月 d 日")
        title = "\(formatter.string(from: plan.start)) · 近 7 天同时段对比"
        formatter.dateFormat = "HH:mm"
        let endLabel = plan.calendar.startOfDay(for: plan.end) > plan.start ? "次日 00:00" : formatter.string(from: plan.end)
        let clockNote = plan.excludedClockDays > 0 ? "另有 \(plan.excludedClockDays) 天因本地时钟或区间长度不同而排除。" : ""
        detail = "比较本地 \(formatter.string(from: plan.start))–\(endLabel)。过去 7 天中，有记录且时长可比的样本为 \(sampleCount)/7 天；至少 3 天才计算均值。无记录日不按零计入，有记录也不代表连续采集。\(clockNote)仅比较记录，不评价效率。"
        if plan.isFuture {
            headline = "所选日期尚未开始。"; baselineActiveSeconds = nil; differenceSeconds = nil
        } else if !current.containsRecordedActivity {
            headline = "所选时段暂无统计记录，暂不比较。"; baselineActiveSeconds = nil; differenceSeconds = nil
        } else if samples.count < 3 {
            headline = "历史样本不足，已有 \(samples.count)/3 个可比记录日。"; baselineActiveSeconds = nil; differenceSeconds = nil
        } else {
            let mean = samples.reduce(0.0) { $0 + Double($1.totalActiveSeconds) } / Double(samples.count)
            let difference = Double(current.totalActiveSeconds) - mean
            baselineActiveSeconds = mean; differenceSeconds = difference
            if abs(difference) < 1 { headline = "记录活跃时长与历史样本均值接近。" }
            else { headline = "记录活跃时长比历史样本均值\(difference > 0 ? "多" : "少") \(insightDuration(abs(difference)))。" }
        }
    }
}

private func validateInsightResponse(_ buckets: [MinuteBucket], segments: [RhythmSegment]) throws {
    guard buckets.count == segments.count, zip(buckets, segments).allSatisfy({ abs($0.start.timeIntervalSince($1.start)) < 0.001 }) else {
        throw NSError(domain: "KeyTrail.Insights", code: 1, userInfo: [NSLocalizedDescriptionKey: "统计返回的时间范围不匹配，请刷新重试。"])
    }
}

private func insightFormatter(calendar: Calendar, format: String) -> DateFormatter {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone; formatter.dateFormat = format; return formatter
}

private func insightDuration(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    if value >= 3600 { return "\(value / 3600) 小时 \(value % 3600 / 60) 分 \(value % 60) 秒" }
    if value >= 60 { return "\(value / 60) 分 \(value % 60) 秒" }
    return "\(value) 秒"
}

private extension ActivitySummary {
    var containsRecordedActivity: Bool { minuteCount > 0 || keyPresses > 0 || totalClicks > 0 || totalActiveSeconds > 0 || mouseDistancePoints > 0 || scrollUnits > 0 }
    mutating func mergeInsightSummary(_ value: ActivitySummary) {
        keyPresses += value.keyPresses; leftClicks += value.leftClicks; rightClicks += value.rightClicks; middleClicks += value.middleClicks
        mouseDistancePoints += value.mouseDistancePoints; scrollUnits += value.scrollUnits
        keyboardActiveSeconds += value.keyboardActiveSeconds; mouseActiveSeconds += value.mouseActiveSeconds; totalActiveSeconds += value.totalActiveSeconds
        minuteCount += value.minuteCount; peakKeysPerMinute = max(peakKeysPerMinute, value.peakKeysPerMinute)
    }
}
