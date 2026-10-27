import KeyTrailCore
import SwiftUI

/// Period insights use their own selection and never substitute the overview's range.
@MainActor
struct RhythmView: View {
    @ObservedObject var model: AppModel

    private var calendar: Calendar {
        var value = Calendar.current
        value.firstWeekday = 2
        return value
    }

    private var requestedWeek: DateInterval? {
        calendar.dateInterval(of: .weekOfYear, for: model.insightsAnchor)
    }

    /// A previous week's response can remain cached in the model while the new one loads.
    private var matchingRhythm: WeeklyRhythm? {
        guard let rhythm = model.weeklyRhythm, let requestedWeek,
              rhythm.weekStart == requestedWeek.start, rhythm.weekEnd == requestedWeek.end else { return nil }
        return rhythm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("节奏周期", selection: $model.insightPeriod) {
                ForEach(InsightPeriod.allCases) { period in Text(period.title).tag(period) }
            }.pickerStyle(.segmented).frame(maxWidth: 240)
            if model.insightPeriod == .week { weeklyContent }
            else { MonthlyRhythmView(model: model) }
        }
    }

    private var weeklyContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            weekPicker
            if model.insightsLoading {
                loadingState
            } else if let error = model.insightsError {
                errorState(error)
            } else if let rhythm = matchingRhythm {
                weekOverview(rhythm)
                RhythmCard(title: "一周的输入节奏", eyebrow: "WEEK × HOUR") {
                    WeeklyRhythmHeatmap(days: rhythm.days)
                    Text("颜色表示已记录的活跃时长；无统计记录，不等于没有活动。未来时段不计为零活动，也不能用空白推断是否工作。")
                        .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
                    Text("按本地时钟分为周一至周日、00–23 时。夏令时重复的小时合并，活动可超过 60 分钟；跳过的小时单独标示。")
                        .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4).padding(.top, 4)
                }
                weeklyReport(rhythm)
            } else {
                unavailableState
            }
        }
    }

    private var weekPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { moveWeek(-1) } label: { Image(systemName: "chevron.left") }
                    .help("上一周").accessibilityLabel("上一周")
                DatePicker("任意一天所在周", selection: $model.insightsAnchor, displayedComponents: [.date])
                    .datePickerStyle(.field).fixedSize()
                Button { moveWeek(1) } label: { Image(systemName: "chevron.right") }
                    .help("下一周").accessibilityLabel("下一周")
                Spacer(minLength: 5)
                Button("本周") { model.insightsAnchor = Date() }
                Button { model.refreshInsights() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }.controlSize(.small)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(weekRangeLabel).font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer(minLength: 5)
                Text("本地周一至周日").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }
            Text("节奏页独立选择一周，不改变总览的导出或删除范围。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
        }.padding(14)
            .background(TrailStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(TrailStyle.line.opacity(0.65), lineWidth: 1))
    }

    private var weekRangeLabel: String {
        guard let week = requestedWeek,
              let lastDay = calendar.date(byAdding: .day, value: -1, to: week.end) else { return "所选本地周" }
        return "\(dateLabel(week.start)) — \(dateLabel(lastDay))"
    }

    private func moveWeek(_ offset: Int) {
        if let next = calendar.date(byAdding: .weekOfYear, value: offset, to: model.insightsAnchor) {
            model.insightsAnchor = next
        }
    }

    private func weekOverview(_ rhythm: WeeklyRhythm) -> some View {
        RhythmCard(title: rhythm.title, eyebrow: model.isDemo ? "WEEKLY OVERVIEW  /  DEMO" : "WEEKLY OVERVIEW") {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text("统计截至 \(rhythm.observedThrough.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))")
                Spacer(minLength: 4)
            }.font(.system(size: 10)).foregroundStyle(TrailStyle.muted).padding(.top, 4)
            Text("本地时区 \(TimeZone.current.identifier) · 截止时间表示日历进度，不代表一直在采集。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
            if rhythm.observedThrough <= rhythm.weekStart {
                Label("这一周尚未开始，未来时段不计为零活动。", systemImage: "calendar.badge.clock")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 14)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], alignment: .leading, spacing: 14) {
                    RhythmMetric(title: "有统计记录", value: "\(rhythm.recordedDayCount)", unit: "天")
                    RhythmMetric(title: "键盘敲击", value: rhythm.summary.keyPresses.formatted(), unit: "次")
                    RhythmMetric(title: "鼠标点击", value: rhythm.summary.totalClicks.formatted(), unit: "次")
                    RhythmMetric(title: "记录活跃时长", value: rhythmDuration(rhythm.summary.totalActiveSeconds), unit: "")
                }.padding(.top, 10)
            }
            if rhythm.recordedDayCount == 0 && rhythm.observedThrough > rhythm.weekStart {
                Label("这一周无统计记录，不等于没有活动。授权状态、暂停或未运行都可能形成空白；这里不作原因推断。", systemImage: "leaf")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4).padding(.top, 8)
            }
        }
    }

    private func weeklyReport(_ rhythm: WeeklyRhythm) -> some View {
        RhythmCard(title: "这一周，留下了什么", eyebrow: "LOCAL WEEKLY NOTES") {
            Text(model.selectedReportText.isEmpty ? "周报尚未生成，请刷新后重试。" : model.selectedReportText)
                .font(.system(size: 13)).lineSpacing(6).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            Divider().overlay(TrailStyle.line.opacity(0.5))
            HStack(spacing: 10) {
                Button { model.copyWeeklyReport() } label: { Label("复制周报", systemImage: "doc.on.doc") }
                Button { model.exportWeeklyReport() } label: { Label("导出 TXT…", systemImage: "square.and.arrow.up") }
                Spacer(minLength: 4)
                if model.isDemo {
                    Text("演示周报").font(.system(size: 10, weight: .medium)).foregroundStyle(TrailStyle.orange)
                }
            }.controlSize(.small).disabled(model.selectedReportText.isEmpty)
            if let notice = model.reportNotice {
                Text(notice).font(.system(size: 11))
                    .foregroundStyle(notice.contains("失败") ? TrailStyle.orange : TrailStyle.teal).textSelection(.enabled)
                    .accessibilityLabel("周报操作结果：\(notice)")
            }
            Text("周报仅根据本机分钟聚合生成，不判断效率、情绪或工作场景。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3).padding(.top, 5)
        }
    }

    private var loadingState: some View {
        RhythmCard(title: "正在读取这一周", eyebrow: "LOCAL RECORDS") {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("正在读取所选周的本地统计并生成周报…")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
            }.frame(maxWidth: .infinity, minHeight: 130, alignment: .center)
        }
    }

    private func errorState(_ error: String) -> some View {
        RhythmCard(title: "这一周暂时无法读取", eyebrow: "LOCAL RECORDS") {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(TrailStyle.orange).textSelection(.enabled)
                .lineSpacing(4).padding(.vertical, 12)
            Button("重试读取所选周") { model.refreshInsights() }.controlSize(.small)
        }
    }

    private var unavailableState: some View {
        RhythmCard(title: "所选周尚未就绪", eyebrow: "LOCAL RECORDS") {
            Text("请刷新读取这一周；此处暂不显示其他周的数据。")
                .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 16)
            Button("读取所选周") { model.refreshInsights() }.controlSize(.small)
        }
    }

    private func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }
}

struct RhythmCard<Content: View>: View {
    let title: String
    let eyebrow: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.7).foregroundStyle(TrailStyle.muted)
            Text(title).font(.system(size: 16, weight: .semibold, design: .serif))
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(TrailStyle.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(TrailStyle.line.opacity(0.55), lineWidth: 1))
    }
}

struct RhythmMetric: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit()
                Text(unit).font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }.lineLimit(1).minimumScaleFactor(0.65)
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(TrailStyle.paper, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Seven small row views keep all 168 cells predictable and cheap to typecheck.
private struct WeeklyRhythmHeatmap: View {
    let days: [RhythmDay]
    private let labelWidth: CGFloat = 62
    private var maximum: Int { max(1, days.flatMap(\.hours).map(\.activeSeconds).max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    VStack(spacing: 7) {
                        hourLabels
                        ForEach(days, id: \.id) { day in
                            RhythmDayRow(day: day, maximum: maximum, labelWidth: labelWidth)
                        }
                    }.frame(width: max(610, geometry.size.width))
                }
            }.frame(height: 318).padding(.top, 10)
            legend
        }
    }

    private var hourLabels: some View {
        HStack(spacing: 3) {
            Text("本地时").font(.system(size: 9)).foregroundStyle(TrailStyle.muted).frame(width: labelWidth, alignment: .leading)
            ForEach(0..<24) { hour in
                Text(hour % 3 == 0 ? String(format: "%02d", hour) : "")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(TrailStyle.muted)
                    .frame(maxWidth: .infinity)
            }
        }.frame(height: 16).accessibilityHidden(true)
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { activityLegend; stateLegend }
            VStack(alignment: .leading, spacing: 10) { activityLegend; stateLegend }
        }
    }

    private var activityLegend: some View {
        HStack(spacing: 5) {
            Text("记录活跃：少").font(.system(size: 9))
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 2).fill(TrailStyle.teal.opacity(0.14 + Double(index) * 0.19)).frame(width: 16, height: 10)
            }
            Text("多").font(.system(size: 9))
        }.foregroundStyle(TrailStyle.muted)
    }

    private var stateLegend: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(TrailStyle.paper).frame(width: 12, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(TrailStyle.line, lineWidth: 1))
            Text("无记录")
            RoundedRectangle(cornerRadius: 2).stroke(TrailStyle.muted.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 12, height: 10)
            Text("未来")
            Text("—").foregroundStyle(TrailStyle.orange)
            Text("时钟跳过")
        }.font(.system(size: 9)).foregroundStyle(TrailStyle.muted)
    }
}

private struct RhythmDayRow: View {
    let day: RhythmDay
    let maximum: Int
    let labelWidth: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(weekdayLabel).font(.system(size: 11, weight: .medium))
                Text(day.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(TrailStyle.muted)
            }.frame(width: labelWidth, alignment: .leading)
            ForEach(day.hours, id: \.id) { hour in
                RhythmHourCell(hour: hour, date: day.date, weekday: weekdayLabel, maximum: maximum)
            }
        }.frame(height: 34)
    }

    private var weekdayLabel: String {
        let labels = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return labels.indices.contains(day.id) ? labels[day.id] : "本地日"
    }
}

private struct RhythmHourCell: View {
    let hour: RhythmHour
    let date: Date
    let weekday: String
    let maximum: Int

    var body: some View {
        RoundedRectangle(cornerRadius: 4).fill(fill)
            .overlay(border)
            .overlay {
                if hour.isMissingClockHour {
                    Text("—").font(.system(size: 10)).foregroundStyle(TrailStyle.orange)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 30)
            .help(description)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description)
    }

    private var fill: Color {
        if hour.isMissingClockHour { return TrailStyle.orange.opacity(0.07) }
        if hour.isFuture { return TrailStyle.surface }
        guard hour.hasRecords else { return TrailStyle.paper }
        let strength = sqrt(Double(max(0, hour.activeSeconds)) / Double(max(1, maximum)))
        return TrailStyle.teal.opacity(0.14 + 0.76 * min(1, strength))
    }

    private var border: some View {
        let color = hour.isMissingClockHour ? TrailStyle.orange.opacity(0.5) : TrailStyle.line.opacity(hour.isFuture ? 0.9 : 0.65)
        return RoundedRectangle(cornerRadius: 4)
            .stroke(color, style: StrokeStyle(lineWidth: 0.8, dash: hour.isFuture ? [2, 2] : []))
    }

    private var description: String {
        let label = "\(date.formatted(.dateTime.year().month().day())) \(weekday) \(String(format: "%02d", hour.id)) 时"
        if hour.isMissingClockHour { return "\(label)：本地时钟跳过的小时；不表示零活动。" }
        if hour.isFuture { return "\(label)：未来时段；尚未到达，不计为零活动。" }
        guard hour.hasRecords else { return "\(label)：无统计记录，不等于没有活动。" }
        let repeated = hour.observedSeconds > 3_600 ? " 本地重复小时已合并。" : ""
        return "\(label)：记录活跃 \(rhythmDuration(hour.activeSeconds))，键盘 \(hour.keyPresses) 次，鼠标点击 \(hour.clicks) 次。\(repeated)"
    }
}

func rhythmDuration(_ seconds: Int) -> String {
    let seconds = max(0, seconds)
    if seconds >= 3_600 { return "\(seconds / 3_600)时 \((seconds % 3_600) / 60)分" }
    if seconds >= 60 { return "\(seconds / 60)分 \(seconds % 60)秒" }
    return "\(seconds)秒"
}
