import KeyTrailCore
import SwiftUI

@MainActor
struct MonthlyRhythmView: View {
    @ObservedObject var model: AppModel

    private var requestedMonth: DateInterval? { Calendar.current.dateInterval(of: .month, for: model.insightsAnchor) }
    private var matchingRhythm: MonthlyRhythm? {
        guard let rhythm = model.monthlyRhythm, let requestedMonth,
              rhythm.start == requestedMonth.start, rhythm.end == requestedMonth.end else { return nil }
        return rhythm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            monthPicker
            if model.insightsLoading { loadingState }
            else if let error = model.insightsError { errorState(error) }
            else if let rhythm = matchingRhythm {
                monthOverview(rhythm)
                RhythmCard(title: "把一个月，铺成日历", eyebrow: "MONTH × DAY") {
                    MonthlyRhythmCalendar(days: rhythm.days, firstWeekdayOffset: rhythm.firstWeekdayOffset)
                    Text("按本地自然日显示，颜色表示已记录的活跃时长。无统计记录，不等于没有活动；未来日期不计为零活动。")
                        .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
                    Text("日期跨越夏令时时，按实际经过时间汇总；不把一天固定当作 24 小时。")
                        .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
                }
                monthlyReport(rhythm)
            } else {
                RhythmCard(title: "所选月尚未就绪", eyebrow: "LOCAL RECORDS") {
                    Text("请刷新读取这个月；此处暂不显示其他月份或周的数据。")
                        .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 12)
                    Button("读取所选月") { model.refreshInsights() }.controlSize(.small)
                }
            }
        }
    }

    private var monthPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .help("上个月").accessibilityLabel("上个月")
                DatePicker("任意一天所在月", selection: $model.insightsAnchor, displayedComponents: [.date])
                    .datePickerStyle(.field).fixedSize()
                Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                    .help("下个月").accessibilityLabel("下个月")
                Spacer(minLength: 5)
                Button("本月") { model.insightsAnchor = Date() }
                Button { model.refreshInsights() } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }.controlSize(.small)
            HStack {
                Text(model.insightsAnchor.formatted(.dateTime.year().month(.wide)))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Spacer()
                Text("本地自然月 · 周一起列").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }
            Text("节奏页独立选择一个月，不改变总览的导出或删除范围。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
        }.padding(14).background(TrailStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(TrailStyle.line.opacity(0.65), lineWidth: 1))
    }

    private func moveMonth(_ offset: Int) {
        // Starting at the month boundary avoids day-31 arithmetic skipping a month.
        guard let start = requestedMonth?.start,
              let next = Calendar.current.date(byAdding: .month, value: offset, to: start) else { return }
        model.insightsAnchor = next
    }

    private func monthOverview(_ rhythm: MonthlyRhythm) -> some View {
        RhythmCard(title: rhythm.title, eyebrow: model.isDemo ? "MONTHLY OVERVIEW  /  DEMO" : "MONTHLY OVERVIEW") {
            Text("统计截至 \(rhythm.observedThrough.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).padding(.top, 4)
            Text("本地时区 \(TimeZone.current.identifier) · 截止时间表示日历进度，不代表一直在采集。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
            if rhythm.observedThrough <= rhythm.start {
                Label("这个月尚未开始，未来日期不计为零活动。", systemImage: "calendar.badge.clock")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.vertical, 14)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 14)], alignment: .leading, spacing: 14) {
                    RhythmMetric(title: "有统计记录", value: "\(rhythm.recordedDayCount)", unit: "天")
                    RhythmMetric(title: "键盘敲击", value: rhythm.summary.keyPresses.formatted(), unit: "次")
                    RhythmMetric(title: "鼠标点击", value: rhythm.summary.totalClicks.formatted(), unit: "次")
                    RhythmMetric(title: "记录活跃时长", value: rhythmDuration(rhythm.summary.totalActiveSeconds), unit: "")
                }.padding(.top, 10)
                if rhythm.recordedDayCount == 0 {
                    Text("这个月无统计记录，不等于没有活动；不从空白判断工作状态。")
                        .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4).padding(.top, 8)
                }
            }
        }
    }

    private func monthlyReport(_ rhythm: MonthlyRhythm) -> some View {
        RhythmCard(title: "这个月，留下了什么", eyebrow: "LOCAL MONTHLY NOTES") {
            Text(model.selectedReportText.isEmpty ? "月报尚未生成，请刷新后重试。" : model.selectedReportText)
                .font(.system(size: 13)).lineSpacing(6).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            Divider().overlay(TrailStyle.line.opacity(0.5))
            HStack(spacing: 10) {
                Button { model.copyWeeklyReport() } label: { Label("复制月报", systemImage: "doc.on.doc") }
                Button { model.exportWeeklyReport() } label: { Label("导出 TXT…", systemImage: "square.and.arrow.up") }
                Spacer(minLength: 4)
                if model.isDemo { Text("演示月报").font(.system(size: 10, weight: .medium)).foregroundStyle(TrailStyle.orange) }
            }.controlSize(.small).disabled(model.selectedReportText.isEmpty)
            if let notice = model.reportNotice {
                Text(notice).font(.system(size: 11)).foregroundStyle(notice.contains("失败") ? TrailStyle.orange : TrailStyle.teal)
                    .textSelection(.enabled).accessibilityLabel("月报操作结果：\(notice)")
            }
            Text("月报仅根据本机分钟聚合生成，不判断效率、情绪或工作场景。")
                .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3).padding(.top, 5)
        }
    }

    private var loadingState: some View {
        RhythmCard(title: "正在读取这个月", eyebrow: "LOCAL RECORDS") {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("正在读取所选月的本地统计并生成月报…").font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
            }.frame(maxWidth: .infinity, minHeight: 130)
        }
    }

    private func errorState(_ error: String) -> some View {
        RhythmCard(title: "这个月暂时无法读取", eyebrow: "LOCAL RECORDS") {
            Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12))
                .foregroundStyle(TrailStyle.orange).textSelection(.enabled).lineSpacing(4).padding(.vertical, 12)
            Button("重试读取所选月") { model.refreshInsights() }.controlSize(.small)
        }
    }
}

private struct MonthlyRhythmCalendar: View {
    let days: [RhythmMonthDay]
    let firstWeekdayOffset: Int
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 7), count: 7)
    private var offset: Int { min(6, max(0, firstWeekdayOffset)) }
    private var slots: Int { ((offset + days.count + 6) / 7) * 7 }
    private var maximum: Int { max(1, days.map { $0.summary.totalActiveSeconds }.max() ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            LazyVGrid(columns: columns, spacing: 7) {
                ForEach(["周一", "周二", "周三", "周四", "周五", "周六", "周日"], id: \.self) { day in
                    Text(day).font(.system(size: 10, weight: .medium)).foregroundStyle(TrailStyle.muted).frame(height: 20)
                }
                ForEach(0..<slots, id: \.self) { slot in
                    if slot >= offset && slot - offset < days.count {
                        RhythmMonthCell(day: days[slot - offset], maximum: maximum)
                    } else {
                        Color.clear.frame(height: 69).accessibilityHidden(true)
                    }
                }
            }.padding(.top, 8)
            calendarLegend
        }
    }

    private var calendarLegend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { intensityLegend; emptyLegend }
            VStack(alignment: .leading, spacing: 10) { intensityLegend; emptyLegend }
        }
    }

    private var intensityLegend: some View {
        HStack(spacing: 5) {
            Text("记录活跃：少")
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 2).fill(TrailStyle.teal.opacity(0.12 + Double(index) * 0.21)).frame(width: 16, height: 10)
            }
            Text("多")
        }.font(.system(size: 9)).foregroundStyle(TrailStyle.muted)
    }

    private var emptyLegend: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(TrailStyle.paper).frame(width: 12, height: 10)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(TrailStyle.line, lineWidth: 1))
            Text("无统计记录")
            RoundedRectangle(cornerRadius: 2).stroke(TrailStyle.line, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 12, height: 10)
            Text("未来日期")
        }.font(.system(size: 9)).foregroundStyle(TrailStyle.muted)
    }
}

private struct RhythmMonthCell: View {
    let day: RhythmMonthDay
    let maximum: Int
    private var strength: Double { sqrt(Double(max(0, day.summary.totalActiveSeconds)) / Double(maximum)) }
    private var dark: Bool { day.hasRecords && !day.isFuture && strength > 0.9 }
    private var fill: Color {
        if day.isFuture { return TrailStyle.surface }
        if !day.hasRecords { return TrailStyle.paper }
        return TrailStyle.teal.opacity(0.12 + 0.84 * min(1, strength))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(day.date.formatted(.dateTime.day())).font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(day.isFuture ? "待到来" : (day.hasRecords ? rhythmDuration(day.summary.totalActiveSeconds) : "无记录"))
                .font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.6)
        }.foregroundStyle(dark ? TrailStyle.surface : TrailStyle.ink)
            .frame(maxWidth: .infinity, minHeight: 49, alignment: .topLeading).padding(10)
            .background(fill, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(TrailStyle.line.opacity(0.75), style: StrokeStyle(lineWidth: 0.8, dash: day.isFuture ? [3, 2] : [])))
            .help(description).accessibilityElement(children: .ignore).accessibilityLabel(description)
    }

    private var description: String {
        let date = day.date.formatted(.dateTime.year().month().day())
        if day.isFuture { return "\(date)：未来日期，尚未到来，不计为零活动。" }
        if !day.hasRecords { return "\(date)：无统计记录，不等于没有活动。" }
        return "\(date)：记录活跃 \(rhythmDuration(day.summary.totalActiveSeconds))，键盘 \(day.summary.keyPresses) 次，鼠标点击 \(day.summary.totalClicks) 次。"
    }
}
