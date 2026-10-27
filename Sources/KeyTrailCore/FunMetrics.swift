import Foundation

public enum FunDistanceReference: String, Codable, CaseIterable, Identifiable, Sendable {
    case equator, beijingGuangzhou, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .equator: return "地球赤道（玩法基准）"
        case .beijingGuangzhou: return "京广线（玩法基准）"
        case .custom: return "自定义路线"
        }
    }
}

public struct FunSettings: Codable, Equatable, Sendable {
    public var reference: FunDistanceReference
    public var customDistanceMeters: Double
    public var metersPerPress: Double

    public init(reference: FunDistanceReference = .equator, customDistanceMeters: Double = 1_000, metersPerPress: Double = 0.01) {
        self.reference = reference; self.customDistanceMeters = customDistanceMeters; self.metersPerPress = metersPerPress
    }

    public var validationError: String? {
        guard metersPerPress.isFinite, metersPerPress > 0, metersPerPress <= 1_000 else {
            return "每次按键的游戏映射须大于 0、且不超过 1,000 米。"
        }
        guard customDistanceMeters.isFinite, customDistanceMeters > 0, customDistanceMeters <= 1_000_000_000_000 else {
            return "自定义参照须大于 0、且不超过 1,000,000,000,000 米。"
        }
        return nil
    }

    /// Rounded game constants, not surveyed route lengths or a movement conversion.
    public var referenceDistanceMeters: Double? {
        guard validationError == nil else { return nil }
        switch reference {
        case .equator: return 40_075_000
        case .beijingGuangzhou: return 2_300_000
        case .custom: return customDistanceMeters
        }
    }
}

/// Only aggregate timing evidence is decoded; no individual timestamps or input order.
public struct TimingInsights: Codable, Sendable {
    public var intervalCount: Int
    public var intervalSumMs: Double
    public var bpm: Double?
    public var burstPeak: Int
    public var burstPeakAt: Date?
    public var measuredMinutes: Int

    public init(intervalCount: Int = 0, intervalSumMs: Double = 0, bpm: Double? = nil, burstPeak: Int = 0, burstPeakAt: Date? = nil, measuredMinutes: Int = 0) {
        self.intervalCount = intervalCount; self.intervalSumMs = intervalSumMs; self.bpm = bpm
        self.burstPeak = burstPeak; self.burstPeakAt = burstPeakAt; self.measuredMinutes = measuredMinutes
    }
}

public struct KeyWearProjection: Identifiable, Sendable {
    public let key: String
    public var id: String { key }
    public let cumulativePresses: Int
    public let sampleDayCount: Int
    public let averagePressesPerRecordedDay: Double?
    public let remainingRecordedDays: Double?
}

public struct CursorDistanceBadge: Identifiable, Sendable {
    public let thresholdPoints: Int
    public let achieved: Bool
    public var id: Int { thresholdPoints }
    public var title: String {
        switch thresholdPoints {
        case 100_000: return "十万显示点"
        case 500_000: return "五十万显示点"
        case 1_000_000: return "百万显示点"
        case 5_000_000: return "五百万显示点"
        default: return "\(thresholdPoints) 显示点"
        }
    }
}

public struct FunMetrics: Sendable {
    public static let wearThreshold = 10_000_000
    public static let energyFormula = "负载 = 按键次数 ÷ 1,000 + 鼠标点击次数 ÷ 250 + 光标显示点 ÷ 100,000；分数 = 向上取整[100 × (1 − e^(−负载))]，限制为 1–100。这三类计数均为零时不生成分数。"
    public static let energyScope = "仅是所选时段累计操作量的趣味刻度，不代表效率、情绪、体力或卡路里；滚动量不参与公式。"

    public let selectedInterval: DateInterval
    public let generatedAt: Date
    public let settings: FunSettings
    public let energyScore: Int?
    public let mappedDistanceMeters: Double?
    public let referenceDistanceMeters: Double?
    public let routeCompletions: Double?
    public let bpm: Double?
    public let intervalSampleCount: Int
    public let timingMeasuredMinutes: Int
    public let burstPeak: Int?
    public let burstPeakMinute: Date?
    public let wearSampleDayCount: Int
    public let wearAveragePressesPerRecordedDay: Double?
    public let wearRemainingRecordedDays: Double?
    public let wearCumulativePresses: Int
    public let wearSampleInterval: DateInterval
    public let keyWear: [KeyWearProjection]
    public let lifetimeMouseDistancePoints: Double?
    public let cursorBadges: [CursorDistanceBadge]

    /// The last thirty completed local dates, expressed as absolute half-open
    /// ranges for a `summaries` query. Fixed 3600-second buckets can cross local
    /// midnight after a half-hour DST change and fabricate distinct sample days.
    public static func historyRanges(now: Date = Date(), calendar: Calendar = .current) -> [DateInterval] {
        let end = calendar.startOfDay(for: now)
        var cursor = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -30, to: end)!)
        var ranges: [DateInterval] = []
        while cursor < end {
            let next = min(end, calendar.dateInterval(of: .day, for: cursor)!.end)
            ranges.append(DateInterval(start: cursor, end: next))
            cursor = next
        }
        return ranges
    }

    public init(summary: ActivitySummary, lifetimeKeyPresses: Int, timing: TimingInsights?, selectedInterval: DateInterval, recentHistory: [MinuteBucket], settings: FunSettings, lifetimeMouseDistancePoints: Double? = nil, lifetimeKeyCounts: [String: Int] = [:], recentKeyCounts: [String: Int] = [:], now: Date = Date(), calendar: Calendar = .current) {
        self.selectedInterval = selectedInterval; generatedAt = now; self.settings = settings
        if let points = lifetimeMouseDistancePoints, points.isFinite, points >= 0 {
            self.lifetimeMouseDistancePoints = points
            cursorBadges = [100_000, 500_000, 1_000_000, 5_000_000].map { CursorDistanceBadge(thresholdPoints: $0, achieved: points >= Double($0)) }
        } else { self.lifetimeMouseDistancePoints = nil; cursorBadges = [] }
        energyScore = Self.energy(summary)
        referenceDistanceMeters = settings.referenceDistanceMeters
        if let reference = referenceDistanceMeters, summary.keyPresses >= 0 {
            let distance = Double(summary.keyPresses) * settings.metersPerPress
            mappedDistanceMeters = distance
            let ratio = distance / reference
            routeCompletions = ratio.isFinite ? ratio : nil
        } else { mappedDistanceMeters = nil; routeCompletions = nil }

        let validTiming = timing.flatMap { value -> TimingInsights? in
            guard value.intervalCount >= 0, value.intervalSumMs.isFinite, value.intervalSumMs >= 0,
                  value.burstPeak >= 0, value.measuredMinutes >= 0 else { return nil }
            return value
        }
        intervalSampleCount = validTiming?.intervalCount ?? 0
        timingMeasuredMinutes = validTiming?.measuredMinutes ?? 0
        if let evidence = validTiming, evidence.intervalCount > 0, evidence.intervalSumMs > 0,
           let reported = evidence.bpm, reported.isFinite {
            let mean = evidence.intervalSumMs / Double(evidence.intervalCount)
            let derived = 60_000 / mean
            bpm = mean >= 30 && mean <= 2_000 && abs(reported - derived) <= max(0.01, derived * 0.000001) ? reported : nil
        } else { bpm = nil }
        if let value = validTiming, value.burstPeak > 0, let date = value.burstPeakAt,
           date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0,
           date >= selectedInterval.start, date < selectedInterval.end {
            burstPeak = value.burstPeak
            // Historical display is intentionally no finer than one minute.
            burstPeakMinute = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
        } else { burstPeak = nil; burstPeakMinute = nil }

        wearCumulativePresses = max(0, lifetimeKeyPresses)
        let end = calendar.startOfDay(for: now)
        let start = Self.historyRanges(now: now, calendar: calendar).first?.start ?? end
        wearSampleInterval = DateInterval(start: start, end: end)
        var recordedDays: [Date: Double] = [:]
        for bucket in recentHistory {
            guard bucket.start.timeIntervalSince1970.isFinite, bucket.start >= start, bucket.start < end,
                  bucket.summary.keyPresses >= 0, Self.hasRecords(bucket.summary) else { continue }
            let day = calendar.startOfDay(for: bucket.start)
            recordedDays[day, default: 0] += Double(bucket.summary.keyPresses)
        }
        wearSampleDayCount = recordedDays.count
        let mean = recordedDays.isEmpty ? nil : recordedDays.values.reduce(0, +) / Double(recordedDays.count)
        wearAveragePressesPerRecordedDay = mean
        if recordedDays.count >= 3, let mean, mean > 0, mean.isFinite, lifetimeKeyPresses >= 0 {
            wearRemainingRecordedDays = Double(max(0, Self.wearThreshold - min(Self.wearThreshold, lifetimeKeyPresses))) / mean
        } else { wearRemainingRecordedDays = nil }
        let dayCount = recordedDays.count
        keyWear = lifetimeKeyCounts.filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(10).map { key, cumulative in
                // The histogram must be supplied independently. Minute/hour totals
                // cannot establish how those presses were distributed among keys.
                let keyMean: Double?
                if dayCount > 0, let count = recentKeyCounts[key], count >= 0 {
                    keyMean = Double(count) / Double(dayCount)
                } else { keyMean = nil }
                let remaining: Double?
                if dayCount >= 3, let keyMean, keyMean > 0 {
                    remaining = Double(max(0, Self.wearThreshold - min(Self.wearThreshold, cumulative))) / keyMean
                } else { remaining = nil }
                return KeyWearProjection(key: key, cumulativePresses: cumulative, sampleDayCount: dayCount, averagePressesPerRecordedDay: keyMean, remainingRecordedDays: remaining)
            }
    }

    /// A frozen aggregate-only appendix. The caller must construct this value for
    /// the report's period; lifetime/sample references are explicitly separate.
    public func reportAppendix(calendar: Calendar = .current) -> String {
        let date = DateFormatter(); date.calendar = calendar; date.timeZone = calendar.timeZone
        date.locale = Locale(identifier: "zh_CN"); date.dateFormat = "yyyy/MM/dd HH:mm"
        func number(_ value: Double, places: Int = 1) -> String {
            if value != 0 && abs(value) < pow(10, -Double(places)) {
                return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
            }
            return String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
        }
        var lines = ["趣味统计附录（非效率评估）", "指标范围：\(date.string(from: selectedInterval.start))（含）至 \(date.string(from: selectedInterval.end))（不含）；时区 \(calendar.timeZone.identifier)。", "生成时刻：\(date.string(from: generatedAt))。"]
        if generatedAt <= selectedInterval.start {
            lines.append("该报告周期尚未开始；不把未来时段记为零活动，也不生成周期分数、距离或节奏结果。")
        } else {
            lines.append(energyScore.map { "操作能量：\($0)/100，仅为本时段累计操作量游戏刻度。" } ?? "操作能量：无可加权计数，不生成分数。")
            lines.append(Self.energyFormula)
            if let meters = mappedDistanceMeters, let reference = referenceDistanceMeters {
                lines.append("游戏旅程：\(number(meters, places: 2)) 游戏米；每物理按键映射 \(number(settings.metersPerPress, places: 6)) 米，参照 \(settings.reference.title) \(number(reference, places: 2)) 米。")
                if let laps = routeCompletions { lines.append("相当于该游戏参照的 \(number(laps, places: 6)) 倍。") }
            } else { lines.append("游戏旅程：玩法设置或计数无有效证据，不生成换算。") }
            lines.append("游戏米数不是字符数、光标移动或身体物理距离；赤道/京广线只采用预设玩法基准。")
            lines.append(bpm.map { "间隔 BPM：\(number($0))；\(intervalSampleCount) 个有效间隔，有节奏聚合的分钟 \(timingMeasuredMinutes) 个。" } ?? "间隔 BPM：不适用，旧数据或有效间隔证据不足，不用按键/分钟或字符/分钟代替。")
            lines.append("BPM 使用 30–2,000ms 有效按键间隔的平均值换算；不表示输入效率。")
            if let burstPeak, let minute = burstPeakMinute {
                lines.append("最高连击：\(burstPeak) 次；所在分钟 \(date.string(from: minute))。超过 750ms、暂停或重启会断开连续性；不显示逐键时间。")
            } else { lines.append("最高连击：无该范围的有效节奏记录，不补造纪录或时间。") }
        }
        lines.append("以下是生成时刻的累计/近期参照，不宣称这些累计量只发生在上述报告周期。")
        if let points = lifetimeMouseDistancePoints {
            let achieved = cursorBadges.filter(\.achieved).map(\.title).joined(separator: "、")
            lines.append("累计光标：\(number(points, places: 0)) pt；已解锁显示点徽章：\(achieved.isEmpty ? "暂无" : achieved)。这是屏幕显示点，非物理米或公里。")
        } else { lines.append("累计光标徽章：累计显示点数据未读取，不评定徽章。") }
        lines.append("千万次玩法：累计全键盘 \(wearCumulativePresses) 次；最近 30 个已结束本地日期有 \(wearSampleDayCount) 个有记录日（\(date.string(from: wearSampleInterval.start)) 至 \(date.string(from: wearSampleInterval.end))，不含终点）。")
        if let mean = wearAveragePressesPerRecordedDay { lines.append("全键盘样本均值：\(number(mean)) 次/有记录日。") }
        if wearCumulativePresses >= Self.wearThreshold { lines.append("全键盘已达千万次游戏阈值，不代表硬件损坏。") }
        else if let days = wearRemainingRecordedDays { lines.append("按样本均值，还需约 \(number(days)) 个有记录日达到千万次阈值。") }
        else { lines.append("全键盘预测：不足 3 个有记录日或均值为零，暂不预测。") }
        if keyWear.isEmpty { lines.append("逐键 Top10 预测：缺少累计按键直方图，不从总次数猜分布。") }
        else {
            lines.append("累计 Top10 逐键千万次玩法（近30日每键频次/全部有记录日）：")
            for key in keyWear {
                let mean = key.averagePressesPerRecordedDay.map { number($0) } ?? "缺频次证据"
                let estimate: String
                if key.cumulativePresses >= Self.wearThreshold { estimate = "已达玩法阈值" }
                else if key.sampleDayCount < 3 { estimate = "不足3日，不预测" }
                else { estimate = key.remainingRecordedDays.map { "还需约\(number($0))个有记录日" } ?? "无有效均值，不预测" }
                lines.append("\(key.key)：累计\(key.cumulativePresses)次，均值\(mean)次/有记录日，\(estimate)。")
            }
        }
        lines.append("缺失日期不补零；有记录但零按键的日期保留。千万次仅作游戏阈值，不是单键耐久、真实日历到达日期或硬件寿命。无统计记录不等于没有活动。")
        return lines.joined(separator: "\n")
    }

    private static func energy(_ value: ActivitySummary) -> Int? {
        guard value.keyPresses >= 0, value.leftClicks >= 0, value.rightClicks >= 0, value.middleClicks >= 0,
              value.mouseDistancePoints.isFinite, value.mouseDistancePoints >= 0 else { return nil }
        let keys = Double(value.keyPresses)
        let clicks = Double(value.leftClicks) + Double(value.rightClicks) + Double(value.middleClicks)
        let points = value.mouseDistancePoints
        guard keys > 0 || clicks > 0 || points > 0 else { return nil }
        let load = keys / 1_000 + clicks / 250 + points / 100_000
        return max(1, min(100, Int(ceil(100 * (1 - exp(-load))))))
    }

    private static func hasRecords(_ value: ActivitySummary) -> Bool {
        value.minuteCount > 0 || value.keyPresses > 0 || value.leftClicks > 0 || value.rightClicks > 0 || value.middleClicks > 0 || value.mouseDistancePoints > 0 || value.scrollUnits > 0 || value.totalActiveSeconds > 0
    }
}
