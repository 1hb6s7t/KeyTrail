import Foundation

public struct RhythmHour: Identifiable, Sendable {
    public let id: Int
    public var activeSeconds = 0
    public var keyPresses = 0
    public var clicks = 0
    /// Elapsed wall time, not proof of collection coverage.
    public var observedSeconds = 0
    public var isFuture = true
    public var isMissingClockHour = true
    public var hasRecords = false
}

public struct RhythmDay: Identifiable, Sendable {
    public let id: Int
    public let date: Date
    public var hours: [RhythmHour]
}

public struct RhythmSegment: Sendable {
    public let start: Date
    public var end: Date
    public let day: Int
    public let hour: Int
}

/// A local Monday-based week, converted to disjoint absolute ranges for Rust.
/// Civil-hour boundaries are found at minute precision so half-hour DST shifts
/// and repeated hours do not move activity into the wrong cell.
public struct WeeklyRhythmPlan: Sendable {
    public let weekStart: Date
    public let weekEnd: Date
    public let observedThrough: Date
    public let calendar: Calendar
    public let dayStarts: [Date]
    public let fullSegments: [RhythmSegment]
    public let querySegments: [RhythmSegment]

    public init(anchor: Date, observedThrough: Date = Date(), calendar: Calendar = .current) {
        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        self.calendar = mondayCalendar
        // A week starting on a midnight clock jump may begin at 01:00. Adding
        // seven days to that instant would incorrectly end the week at 01:00.
        let interval = mondayCalendar.dateInterval(of: .weekOfYear, for: anchor)!
        weekStart = interval.start; weekEnd = interval.end
        let starts = (0..<7).map { day in
            mondayCalendar.startOfDay(for: mondayCalendar.date(byAdding: .day, value: day, to: interval.start)!)
        }
        dayStarts = starts
        let dayIndices = Dictionary(uniqueKeysWithValues: starts.enumerated().map { ($0.element, $0.offset) })
        self.observedThrough = min(weekEnd, observedThrough)
        var segments: [RhythmSegment] = []
        var cursor = weekStart
        while cursor < weekEnd {
            // Compare civil day starts rather than elapsed day components:
            // Monday 01:00 -> Tuesday 00:00 is still the next local date.
            let day = dayIndices[mondayCalendar.startOfDay(for: cursor)]!
            let hour = mondayCalendar.component(.hour, from: cursor)
            let next = min(weekEnd, cursor.addingTimeInterval(60))
            if let last = segments.last, last.day == day, last.hour == hour {
                segments[segments.count - 1].end = next
            } else {
                segments.append(RhythmSegment(start: cursor, end: next, day: day, hour: hour))
            }
            cursor = next
        }
        fullSegments = segments
        let cutoff = self.observedThrough
        querySegments = segments.compactMap { span in
            guard span.start < cutoff else { return nil }
            return RhythmSegment(start: span.start, end: min(span.end, cutoff), day: span.day, hour: span.hour)
        }
    }
}

public struct WeeklyRhythm: Sendable {
    public let weekStart: Date
    public let weekEnd: Date
    public let observedThrough: Date
    public let days: [RhythmDay]
    public let summary: ActivitySummary
    public let recordedDayCount: Int
    public let report: String
    public let title: String

    public init(plan: WeeklyRhythmPlan, buckets: [MinuteBucket], isDemo: Bool = false) throws {
        guard buckets.count == plan.querySegments.count,
              zip(buckets, plan.querySegments).allSatisfy({ abs($0.start.timeIntervalSince($1.start)) < 0.001 }) else {
            throw NSError(domain: "KeyTrail.Rhythm", code: 1, userInfo: [NSLocalizedDescriptionKey: "周统计返回的时间区间不匹配，请刷新重试。"])
        }
        weekStart = plan.weekStart; weekEnd = plan.weekEnd; observedThrough = plan.observedThrough
        var days = (0..<7).map { day in
            RhythmDay(id: day, date: plan.dayStarts[day], hours: (0..<24).map { RhythmHour(id: $0) })
        }
        for span in plan.fullSegments {
            days[span.day].hours[span.hour].isMissingClockHour = false
            if span.start < plan.observedThrough { days[span.day].hours[span.hour].isFuture = false }
        }
        var total = ActivitySummary()
        for (bucket, span) in zip(buckets, plan.querySegments) {
            let value = bucket.summary
            days[span.day].hours[span.hour].activeSeconds += value.totalActiveSeconds
            days[span.day].hours[span.hour].keyPresses += value.keyPresses
            days[span.day].hours[span.hour].clicks += value.totalClicks
            days[span.day].hours[span.hour].observedSeconds += Int(span.end.timeIntervalSince(span.start).rounded(.down))
            days[span.day].hours[span.hour].hasRecords = days[span.day].hours[span.hour].hasRecords || value.hasRhythmRecords
            total.keyPresses += value.keyPresses
            total.leftClicks += value.leftClicks; total.rightClicks += value.rightClicks; total.middleClicks += value.middleClicks
            total.mouseDistancePoints += value.mouseDistancePoints; total.scrollUnits += value.scrollUnits
            total.keyboardActiveSeconds += value.keyboardActiveSeconds; total.mouseActiveSeconds += value.mouseActiveSeconds
            total.totalActiveSeconds += value.totalActiveSeconds; total.minuteCount += value.minuteCount
            total.peakKeysPerMinute = max(total.peakKeysPerMinute, value.peakKeysPerMinute)
        }
        self.days = days; summary = total
        recordedDayCount = days.filter { $0.hours.contains(where: \.hasRecords) }.count
        let date = DateFormatter(); date.locale = Locale(identifier: "zh_CN"); date.calendar = plan.calendar; date.timeZone = plan.calendar.timeZone
        date.dateFormat = "yyyy/MM/dd"
        title = "\(date.string(from: weekStart)) — \(date.string(from: plan.calendar.date(byAdding: .day, value: -1, to: weekEnd)!))"
        date.dateFormat = "yyyy/MM/dd HH:mm"
        var lines = [isDemo ? "键迹周报【演示数据】" : "键迹周报", title, "时区：\(plan.calendar.timeZone.identifier)"]
        if observedThrough < weekStart {
            lines.append("这一周尚未开始，暂无可汇总记录。")
        } else {
            lines.append("统计截至：\(date.string(from: observedThrough))\(observedThrough < weekEnd ? "（本周未结束）" : "（完整自然周区间）")")
            lines.append("有统计记录的日期：\(recordedDayCount) / 7 天。")
            lines.append("键盘敲击 \(total.keyPresses) 次；鼠标点击 \(total.totalClicks) 次。")
            lines.append("键鼠去重活跃时长：\(Self.duration(total.totalActiveSeconds))。")
            lines.append("其中键盘活跃 \(Self.duration(total.keyboardActiveSeconds))，鼠标活跃 \(Self.duration(total.mouseActiveSeconds))；重叠 \(Self.duration(max(0, total.keyboardActiveSeconds + total.mouseActiveSeconds - total.totalActiveSeconds)))。")
            if total.hasRhythmRecords {
                lines.append("光标累计 \(Int(total.mouseDistancePoints.rounded())) pt（屏幕显示点，非物理距离）。")
                let ranked = days.flatMap { day in day.hours.map { (day.id, $0) } }.filter { $0.1.activeSeconds > 0 }
                if let peak = ranked.max(by: { $0.1.activeSeconds < $1.1.activeSeconds }) {
                    lines.append("记录最集中的小时：周\(["一", "二", "三", "四", "五", "六", "日"][peak.0]) \(String(format: "%02d", peak.1.id)):00，累计活跃 \(Self.duration(peak.1.activeSeconds))。")
                }
                lines.append("自然分钟按键峰值：\(total.peakKeysPerMinute) 次/分。")
            } else { lines.append("该时段暂无统计记录。") }
        }
        lines.append("无统计记录不等于没有活动；未开始采集、暂停或应用离线都可能造成空白。")
        lines.append("活跃时长使用输入后的 30 秒窗口，并按实际观察时间去重。重复的本地小时合并显示；夏令时跳过的小时另行标记。")
        lines.append("本周报在本机根据分钟汇总生成，不推断工作内容，也不代表工作效率。")
        report = lines.joined(separator: "\n")
    }

    private static func duration(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分 \(seconds % 60) 秒" }
        if seconds >= 60 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds) 秒"
    }
}

private extension ActivitySummary {
    var hasRhythmRecords: Bool {
        minuteCount > 0 || keyPresses > 0 || totalClicks > 0 || totalActiveSeconds > 0 || mouseDistancePoints > 0 || scrollUnits > 0
    }
}
