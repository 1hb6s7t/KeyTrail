import AppKit
import Charts
import KeyTrailCore
import KeyTrailIPC
import SwiftUI

enum TrailStyle {
    static let journalArtwork: NSImage? = Bundle.main.url(forResource: "journal-keycaps", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    static let paper = Color(red: 0.980, green: 0.980, blue: 0.969)
    static let surface = Color(red: 0.992, green: 0.992, blue: 0.996)
    static let ink = Color(red: 0.13, green: 0.20, blue: 0.32)
    static let muted = Color(red: 0.42, green: 0.45, blue: 0.56)
    static let teal = Color(red: 0.34, green: 0.43, blue: 0.78)
    static let orange = Color(red: 0.62, green: 0.58, blue: 0.79)
    static let line = Color(red: 0.85, green: 0.86, blue: 0.93)
    static let lavender = Color(red: 0.69, green: 0.67, blue: 0.88)
    static func editorial(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Songti SC", size: size).weight(weight)
    }
}

private enum TrailPage: String, CaseIterable {
    case overview = "总览", keyboard = "键盘", rhythm = "节奏", text = "文字", settings = "设置"
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .keyboard: return "keyboard"
        case .rhythm: return "square.grid.3x3.fill"
        case .text: return "text.magnifyingglass"
        case .settings: return "slider.horizontal.3"
        }
    }
    var subtitle: String {
        switch self {
        case .overview: return "每一次敲击，都有迹可循。"
        case .keyboard: return "看看你的指尖，习惯走哪条路。"
        case .rhythm: return "让每一段记录，呈现自己的节奏。"
        case .text: return "可选文字记录，由你决定何时开始。"
        case .settings: return "你的数据，始终由你掌握。"
        }
    }
}

@MainActor
struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var page: TrailPage = .overview
    @State private var deletion: Deletion?
    @State private var exportError: String?
    @State private var hoveredActivity: Date?
    @State private var showDetails = false
    @State private var showDatePicker = false

    private enum Deletion: Identifiable {
        case selected(DateInterval), all
        var id: String { isAll ? "all" : "selected" }
        var isAll: Bool { if case .all = self { return true }; return false }
    }

    var body: some View {
        VStack(spacing: 0) {
            journalTopBar
            Rectangle().fill(TrailStyle.line).frame(height: 1)
            HStack(spacing: 0) {
                journalDateRail
                Rectangle().fill(TrailStyle.line).frame(width: 1)
                VStack(spacing: 0) {
                    if model.isDemo { demoBanner }
                    else if RuntimePaths.isValidation {
                        Text("本机验证版 · 独立验证数据库")
                            .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).padding(8)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if let error = model.errorMessage { errorBanner(error) }
                            if let notice = model.csvExportNotice {
                                HStack {
                                    if model.csvExporting { ProgressView().controlSize(.small) }
                                    Text(notice).font(.system(size: 12)).textSelection(.enabled)
                                    Spacer()
                                    if model.csvExporting { Button("取消 CSV 导出") { model.cancelCSVExport() } }
                                }.foregroundStyle(TrailStyle.muted)
                            }
                            if page != .overview { journalPageHeading }
                            if page != .overview && page != .settings && page != .rhythm { rangePicker }
                            switch page {
                            case .overview: overview
                            case .keyboard: if model.funEnabled { keyboardPage } else { overview }
                            case .rhythm: if model.funEnabled { RhythmView(model: model) } else { overview }
                            case .text: TextHistoryView(model: model, onOpenSettings: { page = .settings })
                            case .settings: settingsPage
                            }
                            if page != .overview && page != .rhythm && page != .text { footer }
                        }
                        .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 24)
                        .frame(maxWidth: 1500).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .background(TrailStyle.paper)
        .foregroundStyle(TrailStyle.ink)
        .tint(TrailStyle.teal)
        .frame(minWidth: 1020, minHeight: 720)
        .preferredColorScheme(.light)
        .onChange(of: model.rangeMode) { _, _ in model.refresh() }
        .onChange(of: model.selectedDate) { _, _ in model.refresh() }
        .onChange(of: model.customStart) { _, _ in model.refresh() }
        .onChange(of: model.customEnd) { _, _ in model.refresh() }
        .onAppear {
            model.refreshRuntimeDetails()
            model.setInsightsVisible(page == .rhythm && model.funEnabled)
            model.setOverviewVisible(page == .overview && model.funEnabled)
        }
        .onDisappear { model.setInsightsVisible(false); model.setOverviewVisible(false) }
        .onChange(of: page) { _, selected in
            model.setInsightsVisible(selected == .rhythm && model.funEnabled)
            model.setOverviewVisible(selected == .overview && model.funEnabled)
        }
        .onChange(of: model.insightsAnchor) { _, _ in
            if page == .rhythm && model.funEnabled { model.refreshInsights() }
        }
        .onChange(of: model.insightPeriod) { _, _ in
            if page == .rhythm && model.funEnabled { model.refreshInsights() }
        }
        .onChange(of: model.funEnabled) { _, enabled in
            if !enabled && (page == .keyboard || page == .rhythm) { page = .overview }
            model.setInsightsVisible(page == .rhythm && enabled)
            model.setOverviewVisible(page == .overview && enabled)
        }
        .alert(item: $deletion) { item in
            Alert(
                title: Text(item.isAll ? "清空全部统计与文字记录？" : "删除所选时段的统计与文字？"),
                message: Text(deletionMessage(item)),
                primaryButton: .destructive(Text("确认删除")) {
                    switch item {
                    case .all: model.clearAll()
                    case .selected(let interval): model.deleteSelectedRange(in: interval)
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .alert("图谱导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("知道了", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var journalTopBar: some View {
        GeometryReader { geometry in
        let compact = geometry.size.width < 1200
        HStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("键迹").font(TrailStyle.editorial(30, weight: .bold))
                Text("KEYTRAIL").font(.system(size: 9, weight: .semibold, design: .serif)).tracking(3)
            }.frame(width: compact ? 200 : 250, alignment: .center)
            HStack(spacing: compact ? 20 : 58) {
                ForEach(TrailPage.allCases.filter { model.funEnabled || ($0 != .keyboard && $0 != .rhythm) }, id: \.self) { item in
                    Button { page = item } label: {
                        Text(item.rawValue).font(.system(size: 15, weight: page == item ? .semibold : .regular))
                            .foregroundStyle(page == item ? TrailStyle.teal : TrailStyle.muted)
                            .frame(minWidth: 42).frame(height: 46)
                            .overlay(alignment: .bottom) {
                                if page == item { Capsule().fill(TrailStyle.teal).frame(height: 3).padding(.bottom, 4) }
                            }
                    }.buttonStyle(.plain)
                }
            }.padding(.leading, compact ? 20 : 100)
            Spacer(minLength: 18)
            HStack(spacing: 8) {
                Circle().fill(model.isMonitoring ? Color.green : TrailStyle.muted).frame(width: 8, height: 8)
                Text(model.isDemo ? "演示数据" : model.isMonitoring ? "正在记录" : model.isPaused ? "已暂停" : "未在记录")
                    .font(.system(size: 13)).help(model.statusText)
            }
            if !model.isDemo {
                Button {
                    if model.isMonitoring { model.pause() }
                    else if model.isPaused { model.resume() }
                    else { model.startMonitoring() }
                } label: {
                    Label(model.isMonitoring ? "暂停" : model.isPaused ? "继续记录" : "开始记录", systemImage: model.isMonitoring ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 12)
                        .foregroundStyle(.white).background(TrailStyle.teal, in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).padding(.leading, 26)
                    .contextMenu {
                        if model.isMonitoring {
                            Button("暂停 15 分钟") { model.pause(minutes: 15) }
                            Button("暂停 1 小时") { model.pause(minutes: 60) }
                        }
                    }
            }
        }.padding(.trailing, 28).frame(height: 50)
        }.frame(height: 50)
    }

    private var journalAnchor: Date { model.rangeMode == .today ? Date() : model.rangeMode == .custom ? model.customStart : model.selectedDate }
    private func journalDate(_ date: Date, _ format: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = format; return f.string(from: date)
    }
    private var journalWeek: [Date] {
        var calendar = Calendar.current; calendar.firstWeekday = 2
        let start = calendar.dateInterval(of: .weekOfYear, for: journalAnchor)?.start ?? calendar.startOfDay(for: journalAnchor)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    private func shiftJournalDate(_ amount: Int) {
        let component: Calendar.Component = model.rangeMode == .month ? .month : model.rangeMode == .year ? .year : .weekOfYear
        model.selectedDate = Calendar.current.date(byAdding: component, value: amount, to: journalAnchor) ?? journalAnchor
        if model.rangeMode == .today || model.rangeMode == .custom { model.rangeMode = .day }
    }
    private var journalDateRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { showDatePicker.toggle() } label: {
                    Text(journalDate(journalAnchor, "yyyy 年 M 月")).font(TrailStyle.editorial(17, weight: .semibold))
                }.buttonStyle(.plain).popover(isPresented: $showDatePicker) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("选择统计日期").font(.headline)
                        DatePicker("日期", selection: $model.selectedDate, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                        Button("查看这一天") { model.rangeMode = .day; showDatePicker = false }
                    }.padding(20)
                }
                Spacer(minLength: 6)
                Button { shiftJournalDate(-1) } label: { Image(systemName: "chevron.left") }.help("上一周期")
                Button { shiftJournalDate(1) } label: { Image(systemName: "chevron.right") }.padding(.leading, 7).help("下一周期")
            }.buttonStyle(.plain).foregroundStyle(TrailStyle.ink)
            Text(journalDate(journalAnchor, "d")).font(TrailStyle.editorial(175)).tracking(-7).fixedSize().frame(height: 158).padding(.top, 4)
            Text(journalDate(journalAnchor, "EEEE").replacingOccurrences(of: "星期", with: "周"))
                .font(TrailStyle.editorial(30, weight: .bold)).padding(.top, -5)
            Button { model.selectedDate = Date(); model.rangeMode = .today; page = .overview } label: {
                Text("今天").font(.system(size: 14)).foregroundStyle(TrailStyle.teal)
                    .padding(.horizontal, 23).padding(.vertical, 7)
                    .background(TrailStyle.teal.opacity(0.10), in: Capsule())
            }.buttonStyle(.plain).padding(.top, 24).padding(.bottom, 22)
            VStack(spacing: 5) {
                ForEach(journalWeek, id: \.self) { date in
                    let selected = Calendar.current.isDate(date, inSameDayAs: journalAnchor)
                    Button { model.selectedDate = date; model.rangeMode = .day; page = .overview } label: {
                        HStack(spacing: 22) {
                            Text(journalDate(date, "d")).font(TrailStyle.editorial(21)).frame(width: 25, alignment: .leading)
                            Text(journalDate(date, "EEEEE")).font(.system(size: 14))
                            Spacer()
                            if selected { Circle().fill(TrailStyle.teal).frame(width: 7, height: 7) }
                        }.foregroundStyle(selected ? TrailStyle.teal : date > Date() ? TrailStyle.muted.opacity(0.65) : TrailStyle.ink)
                            .padding(.horizontal, 12).frame(height: 39)
                            .background(selected ? TrailStyle.teal.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).accessibilityLabel(journalDate(date, "M月d日 EEEE"))
                }
            }
            Spacer(minLength: 36)
            Rectangle().fill(TrailStyle.line).frame(height: 1).padding(.bottom, 28)
            HStack(spacing: 11) {
                Image(systemName: "laptopcomputer").font(.system(size: 21))
                Text("本机保存").font(.system(size: 14))
                Spacer(); Circle().fill(TrailStyle.teal).frame(width: 7, height: 7)
            }.padding(.bottom, 22)
            privacyStatus("文字记录", enabled: model.runtimeDetails?.preferences.textRecordingEnabled)
            privacyStatus("同步", enabled: model.runtimeDetails?.preferences.syncEnabled).padding(.top, 18)
        }.padding(.horizontal, 28).padding(.top, 35).padding(.bottom, 28).frame(width: 250)
    }
    private func privacyStatus(_ title: String, enabled: Bool?) -> some View {
        Button { page = .settings } label: {
            HStack {
                Text(title); Text(enabled.map { $0 ? "开启" : "关闭" } ?? "读取中").font(.system(size: 12))
                Spacer(); Circle().fill(enabled == true ? TrailStyle.teal : TrailStyle.muted.opacity(0.4)).frame(width: 7, height: 7)
            }.font(.system(size: 13)).foregroundStyle(TrailStyle.muted)
        }.buttonStyle(.plain)
    }
    private var journalPageHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(page.rawValue).font(TrailStyle.editorial(38, weight: .bold))
            Text(page.subtitle).font(.system(size: 14)).foregroundStyle(TrailStyle.muted)
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            journalHero
            Rectangle().fill(TrailStyle.line).frame(height: 1)
            journalMetrics.padding(.vertical, 15)
            Rectangle().fill(TrailStyle.line).frame(height: 1)
            journalActivity.padding(.top, 18).padding(.bottom, 14)
            journalFun
            DisclosureGroup("更多统计与导出", isExpanded: $showDetails) {
                detailedOverview.padding(.top, 20)
            }.font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.top, 18)
            if showDetails { footer.padding(.top, 18) }
        }
    }
    private var journalHero: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.rangeMode == .today ? "今天留下的记录" : "这段时光的记录")
                    .font(TrailStyle.editorial(48, weight: .bold)).lineLimit(1).minimumScaleFactor(0.65).frame(height: 60)
                Text(model.rangeMode == .today || model.rangeMode == .day ? journalDate(journalAnchor, "yyyy 年 M 月 d 日 · EEEE").replacingOccurrences(of: "星期", with: "周") : model.rangeTitle)
                    .font(.system(size: 16)).foregroundStyle(TrailStyle.muted)
                HStack(spacing: 14) {
                    journalIcon("clock")
                    Text("活跃时长").font(TrailStyle.editorial(23, weight: .bold))
                }.padding(.top, 14)
                journalDurationText(model.summary.totalActiveSeconds)
                    .foregroundStyle(TrailStyle.teal).lineLimit(1).minimumScaleFactor(0.6).fixedSize(horizontal: false, vertical: true).frame(height: 80)
                    .padding(.leading, 51).padding(.top, -8)
                Text("键鼠重叠时间已去重。")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.leading, 54)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.funEnabled {
                ZStack(alignment: .trailing) {
                    if let asset = TrailStyle.journalArtwork {
                        Image(nsImage: asset).resizable().scaledToFit().frame(maxWidth: .infinity).padding(.trailing, 105)
                            .accessibilityHidden(true)
                    }
                    VStack(spacing: 13) {
                        Image(systemName: model.lifetime.keyPresses >= 100_000 ? "medal.fill" : "medal")
                            .font(.system(size: 37, weight: .ultraLight)).foregroundStyle(TrailStyle.teal)
                            .frame(width: 72, height: 72).overlay(Circle().stroke(TrailStyle.lavender, lineWidth: 1))
                        Text(model.lifetime.keyPresses >= 100_000 ? "累计十万次" : "每一击，都算数")
                            .font(TrailStyle.editorial(19, weight: .bold))
                        Text(model.lifetime.keyPresses >= 100_000 ? "一枚属于你的记录徽章。" : "累计 \(number(model.lifetime.keyPresses)) 次敲击")
                            .font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
                    }.frame(width: 170)
                }.frame(maxWidth: .infinity).frame(height: 235)
            }
        }.frame(minHeight: 235).padding(.bottom, 16)
    }
    private func journalDurationText(_ seconds: Int) -> Text {
        func number(_ value: Int) -> Text { Text("\(value)").font(TrailStyle.editorial(88)) }
        func unit(_ value: String) -> Text { Text(value).font(TrailStyle.editorial(36)) }
        if seconds >= 3600 { return number(seconds / 3600) + unit("小时") + number((seconds % 3600) / 60) + unit("分") }
        if seconds >= 60 { return number(seconds / 60) + unit("分") + number(seconds % 60) + unit("秒") }
        return number(seconds) + unit("秒")
    }
    private func journalDuration(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)小时\((seconds % 3600) / 60)分" }
        if seconds >= 60 { return "\(seconds / 60)分\(seconds % 60)秒" }
        return "\(seconds)秒"
    }
    private func journalIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 21)).foregroundStyle(TrailStyle.teal)
            .frame(width: 43, height: 43).background(TrailStyle.teal.opacity(0.07), in: Circle())
    }
    private var journalMetrics: some View {
        HStack(spacing: 26) {
            journalMetric("键盘敲击", value: number(model.summary.keyPresses), unit: "次", symbol: "keyboard", help: "物理按键次数，不含长按重复")
            Rectangle().fill(TrailStyle.line).frame(width: 1, height: 64)
            journalMetric("鼠标点击", value: number(model.summary.totalClicks), unit: "次", symbol: "computermouse", help: "左键 \(model.summary.leftClicks) · 右键 \(model.summary.rightClicks) · 中键 \(model.summary.middleClicks)")
            Rectangle().fill(TrailStyle.line).frame(width: 1, height: 64)
            journalMetric("光标距离（屏幕点）", value: model.summary.mouseDistancePoints >= 1000 ? String(format: "%.1f", model.summary.mouseDistancePoints / 1000) : String(format: "%.0f", model.summary.mouseDistancePoints), unit: model.summary.mouseDistancePoints >= 1000 ? "kpt" : "pt", symbol: "cursorarrow", help: "屏幕显示点距离，不是桌面物理距离")
        }
    }
    private func journalMetric(_ title: String, value: String, unit: String, symbol: String, help: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            journalIcon(symbol)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(TrailStyle.editorial(43)).lineLimit(1).minimumScaleFactor(0.5)
                    Text(unit).font(TrailStyle.editorial(24))
                }
                Text(title).font(.system(size: 14)).foregroundStyle(TrailStyle.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).help(help)
    }
    private var journalRangeTabs: some View {
        HStack(spacing: 4) {
            ForEach([RangeMode.today, .week, .month, .custom]) { mode in
                Button {
                    if mode == .today || mode == .week || mode == .month { model.selectedDate = Date() }
                    model.rangeMode = mode
                } label: {
                    Text(mode == .month ? "本月" : mode.title).font(.system(size: 13))
                        .padding(.horizontal, 17).padding(.vertical, 8)
                        .foregroundStyle(model.rangeMode == mode ? TrailStyle.teal : TrailStyle.muted)
                        .background(model.rangeMode == mode ? TrailStyle.teal.opacity(0.13) : .clear, in: Capsule())
                }.buttonStyle(.plain)
            }
            Menu {
                Button("按日查看") { model.rangeMode = .day }
                Button("按年查看") { model.rangeMode = .year }
                Button("刷新统计") { model.refresh() }
                Button("导出 CSV") { model.exportCSV() }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
        }
    }
    private struct JournalActivityPoint: Identifiable {
        var start: Date; var queryStart: Date; var end: Date; var minutes: Double
        var id: Date { start }
    }
    private var journalPoints: [JournalActivityPoint] {
        guard let plan = model.overviewTrendPlan, plan.segments.count == model.buckets.count else { return [] }
        return zip(plan.segments, model.buckets).map { segment, bucket in
            JournalActivityPoint(start: segment.displayStart, queryStart: segment.start, end: segment.end, minutes: Double(bucket.summary.totalActiveSeconds) / 60)
        }
    }
    private var journalActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.rangeMode == .today || model.rangeMode == .day ? "一天的节奏" : "时光的节奏", systemImage: "chart.bar.xaxis")
                    .font(TrailStyle.editorial(25, weight: .bold))
                Spacer(); journalRangeTabs
            }
            if model.rangeMode == .custom || model.rangeMode == .year { rangePicker }
            if let error = model.trendError { errorBanner(error) }
            Text("活跃分钟").font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
            Chart {
                ForEach(journalPoints) { point in
                    BarMark(x: .value("时间", point.start, unit: trendComponent), y: .value("活跃分钟", point.minutes), width: .ratio(0.55))
                        .foregroundStyle(hoveredActivity == point.start ? TrailStyle.teal : TrailStyle.lavender)
                        .cornerRadius(3)
                    if hoveredActivity == point.start {
                        RuleMark(x: .value("时间", point.start)).foregroundStyle(TrailStyle.teal.opacity(0.25))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                VStack(spacing: 3) {
                                    Text(journalDate(point.start, trendComponent == .hour ? "HH:mm" : "M月d日"))
                                    Text(String(format: "%.1f 分钟", point.minutes))
                                }.font(.system(size: 11)).foregroundStyle(.white).padding(8)
                                    .background(TrailStyle.ink, in: RoundedRectangle(cornerRadius: 7))
                            }
                    }
                }
            }
            .chartXScale(domain: model.selectedInterval.start...max(model.selectedInterval.start.addingTimeInterval(60), model.selectedInterval.end))
            .chartYScale(domain: 0...max(trendComponent == .hour ? 60 : 5, journalPoints.map(\.minutes).max() ?? 0))
            .chartXAxis {
                AxisMarks(values: .stride(by: trendComponent, count: 1)) { value in
                    AxisValueLabel { if let date = value.as(Date.self) { Text(axisLabel(date)).font(.system(size: 10, design: .serif)) } }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 4])).foregroundStyle(TrailStyle.line)
                    AxisValueLabel().font(.system(size: 10, design: .serif))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { return }
                                let x = location.x - geometry[frame].origin.x
                                if x >= 0, x < geometry[frame].width, let date: Date = proxy.value(atX: x) {
                                    hoveredActivity = journalPoints.first(where: { date >= $0.queryStart && date < $0.end })?.start
                                } else { hoveredActivity = nil }
                            case .ended: hoveredActivity = nil
                            }
                        }
                }
            }
            .frame(height: 126)
            .accessibilityLabel("所选时段的去重活跃分钟趋势")
            if journalPoints.allSatisfy({ $0.minutes == 0 }) {
                Text("这个时段尚无活动记录。").font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
            }
        }
    }
    private var journalFun: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Label("趣味面板", systemImage: "gamecontroller").font(TrailStyle.editorial(23, weight: .bold))
                Toggle("趣味面板", isOn: $model.funEnabled).labelsHidden().toggleStyle(JournalToggleStyle())
                Spacer()
                if model.funEnabled {
                    Button("查看全部", systemImage: "arrow.right") { page = .keyboard }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(TrailStyle.teal)
                }
            }
            if model.funEnabled {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("键盘热区", systemImage: "keyboard").font(.system(size: 12, weight: .medium))
                            Spacer(); Text("少").font(.system(size: 9))
                            ForEach(0..<5) { index in Circle().fill(TrailStyle.teal.opacity(0.12 + Double(index) * 0.2)).frame(width: 8, height: 8) }
                            Text("多").font(.system(size: 9))
                        }
                        compactKeyboard
                    }.frame(maxWidth: .infinity)
                    Rectangle().fill(TrailStyle.line).frame(width: 1, height: 132)
                    VStack(alignment: .leading, spacing: 15) {
                        Label("常用按键", systemImage: "chart.bar").font(.system(size: 12, weight: .medium))
                        if topKeys.isEmpty {
                            Text("尚无按键记录").font(.system(size: 12)).foregroundStyle(TrailStyle.muted).padding(.top, 24)
                        } else {
                            ForEach(Array(topKeys.prefix(3).enumerated()), id: \.element.key) { index, item in
                                HStack(spacing: 12) {
                                    Text("\(index + 1)").foregroundStyle(TrailStyle.teal)
                                    Text(item.key == "Delete" ? "Backspace" : item.key).frame(width: 67, alignment: .leading).lineLimit(1)
                                    GeometryReader { geo in
                                        RoundedRectangle(cornerRadius: 4).fill(TrailStyle.lavender.opacity(0.2))
                                            .overlay(alignment: .leading) {
                                                RoundedRectangle(cornerRadius: 4).fill(TrailStyle.lavender)
                                                    .frame(width: geo.size.width * Double(item.value) / Double(max(1, topKeys.first?.value ?? 1)))
                                            }
                                    }.frame(height: 14)
                                    Text(number(item.value)).frame(width: 40, alignment: .trailing)
                                }.font(.system(size: 11)).frame(height: 22)
                            }
                        }
                    }.frame(width: 290)
                }.padding(12).background(TrailStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            }
        }.padding(15).background(TrailStyle.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
    }
    private var compactKeyboard: some View {
        VStack(spacing: 4) {
            compactKeyRow(["Esc", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "Delete"])
            compactKeyRow(["Tab", "A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'", "Return"])
            compactKeyRow(["Shift", "Z", "X", "C", "V", "B", "N", "M", ",", ".", "/", "Shift"])
            compactKeyRow(["Ctrl", "Option", "Cmd", "Space", "Cmd", "Option", "Ctrl"])
        }
    }
    private func compactKeyRow(_ keys: [String]) -> some View {
        GeometryReader { geometry in
            let total = keys.reduce(0.0) { $0 + compactKeyWeight($1) }
            let available = max(1, geometry.size.width - CGFloat(keys.count - 1) * 4)
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    let count = countForKey(key)
                    let strength = count == 0 ? 0 : 0.2 + 0.65 * sqrt(min(1, Double(count) / Double(max(1, topKeys.first?.value ?? 1))))
                    Text(key == "Space" ? "" : key == "Delete" ? "Backspace" : key == "Cmd" ? "⌘" : key)
                        .font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(strength > 0.45 ? .white : TrailStyle.ink)
                        .frame(width: available * compactKeyWeight(key) / total, height: 23)
                        .background(count == 0 ? TrailStyle.surface : TrailStyle.teal.opacity(strength), in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(TrailStyle.line, lineWidth: 0.7))
                        .help("\(key)：\(number(count)) 次").accessibilityLabel("\(key)，\(count) 次")
                }
            }
        }.frame(height: 23)
    }
    private func compactKeyWeight(_ key: String) -> Double {
        key == "Space" ? 5.5 : ["Delete", "Return", "Shift"].contains(key) ? 1.8 : key.count > 2 ? 1.4 : 1
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(TrailStyle.teal).frame(width: 38, height: 38)
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 21, weight: .medium)).foregroundStyle(TrailStyle.paper)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("键迹").font(.system(size: 23, weight: .semibold, design: .serif))
                    Text("KEYTRAIL").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2)
                }
            }.padding(.bottom, 42)
            Text("我的工作节奏").font(.system(size: 10, weight: .medium)).foregroundStyle(TrailStyle.muted).padding(.leading, 13).padding(.bottom, 12)
            ForEach(TrailPage.allCases.filter { model.funEnabled || ($0 != .keyboard && $0 != .rhythm) }, id: \.self) { item in
                Button { page = item } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.icon).font(.system(size: 15)).frame(width: 21)
                        Text(item.rawValue).font(.system(size: 14, weight: page == item ? .semibold : .regular))
                        Spacer()
                        if page == item { Circle().fill(TrailStyle.teal).frame(width: 5, height: 5) }
                    }
                    .foregroundStyle(page == item ? TrailStyle.teal : TrailStyle.muted)
                    .padding(.horizontal, 13).padding(.vertical, 12)
                    .background(page == item ? TrailStyle.teal.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.bottom, 5)
            }
            Spacer(minLength: 30)
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: "externaldrive.badge.checkmark").font(.system(size: 22)).foregroundStyle(TrailStyle.teal)
                Text("默认留在你的 Mac").font(.system(size: 12, weight: .semibold))
                Text("默认只记录聚合统计。\n文字与私有同步需主动开启。")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
                Text("LOCAL FIRST  /  v1.2 DEV")
                    .font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(TrailStyle.muted).padding(.top, 8)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(TrailStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        }.padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 22).frame(width: 190)
    }

    private var demoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
            Text("演示模式").fontWeight(.semibold)
            Text("独立演示数据库 · 以下为生成数据 · 不监听真实输入")
            Spacer()
        }.font(.system(size: 11)).foregroundStyle(TrailStyle.orange)
            .padding(.horizontal, 30).padding(.vertical, 10).background(TrailStyle.orange.opacity(0.10))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(page.rawValue).font(.system(size: 29, weight: .semibold, design: .serif))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(model.isMonitoring ? TrailStyle.teal : TrailStyle.orange).frame(width: 6, height: 6)
                    Text(model.statusText).font(.system(size: 11, weight: .medium)).lineLimit(1)
                }
                if !model.isDemo {
                    if model.isMonitoring {
                        Menu {
                            Button("暂停 15 分钟") { model.pause(minutes: 15) }
                            Button("暂停 1 小时") { model.pause(minutes: 60) }
                            Button("暂停，直到手动继续") { model.pause() }
                        } label: { Label("暂停统计", systemImage: "pause") }
                        .menuStyle(.borderlessButton).fixedSize()
                    } else {
                        Button {
                            if model.isPaused { model.resume() } else { model.startMonitoring() }
                        } label: {
                            Label(model.isPaused ? "继续统计" : (model.permissionGranted ? "开始统计" : "授权并开始"), systemImage: "play.fill")
                        }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }
        }
    }

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(RangeMode.allCases) { mode in
                    Button { model.rangeMode = mode } label: {
                        Text(mode.title).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundStyle(model.rangeMode == mode ? TrailStyle.surface : TrailStyle.muted)
                            .background(model.rangeMode == mode ? TrailStyle.teal : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 8)
                if page != .text {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 13)) }
                        .buttonStyle(.plain).help("刷新统计").accessibilityLabel("刷新统计")
                }
            }
            HStack(spacing: 12) {
                if model.rangeMode == .custom {
                    DatePicker("起点", selection: $model.customStart, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                    Text("至").foregroundStyle(TrailStyle.muted)
                    DatePicker("终点", selection: $model.customEnd, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                } else if model.rangeMode != .today {
                    DatePicker("选择日期", selection: $model.selectedDate, displayedComponents: [.date]).labelsHidden()
                }
                Text(model.rangeTitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(TrailStyle.muted).lineLimit(2)
                Spacer(minLength: 0)
                if model.rangeMode != .custom {
                    Text("本地日历").font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                }
            }.controlSize(.small)
            if model.rangeMode == .custom {
                Text("按分钟选择，包含起点、不包含终点。删除时覆盖所选的完整分钟。")
                    .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }
        }.padding(14).background(TrailStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(TrailStyle.line.opacity(0.65), lineWidth: 1))
    }

    private var detailedOverview: some View {
        VStack(alignment: .leading, spacing: 22) {
            if isEmpty { emptyNotice }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 195), spacing: 13)], spacing: 13) {
                MetricTile(title: "键盘敲击", value: number(model.summary.keyPresses), unit: "次", icon: "keyboard", note: "物理按键次数 · 不含长按重复", accent: TrailStyle.teal)
                MetricTile(title: "鼠标点击", value: number(model.summary.totalClicks), unit: "次", icon: "cursorarrow.click", note: "左 \(number(model.summary.leftClicks))  /  右 \(number(model.summary.rightClicks))  /  中 \(number(model.summary.middleClicks))", accent: TrailStyle.orange)
                MetricTile(title: "活跃时长", value: duration(model.summary.totalActiveSeconds), unit: "", icon: "clock", note: "键鼠活动去重 · 不计暂停与休眠", accent: TrailStyle.teal)
                MetricTile(title: "光标里程", value: compactDistance(model.summary.mouseDistancePoints), unit: "pt", icon: "point.topleft.down.to.point.bottomright.curvepath", note: "屏幕显示点距离 · 非桌面物理距离", accent: TrailStyle.orange)
            }
            if model.funEnabled && (model.rangeMode == .today || model.rangeMode == .day) {
                DailyComparisonCard(comparison: model.dailyComparison, isLoading: model.comparisonLoading, error: model.comparisonError) { model.refresh() }
            }
            panel("输入节奏", eyebrow: "ACTIVITY RHYTHM", trailing: "键盘与鼠标点击次数") {
                if let error = model.trendError {
                    Text(error + "；上方摘要仍可查看。请刷新重试。")
                        .font(.system(size: 12)).foregroundStyle(TrailStyle.orange)
                } else { trendChart }
                HStack(spacing: 20) {
                    chartLegend("键盘敲击", color: TrailStyle.teal)
                    chartLegend("鼠标点击", color: TrailStyle.orange)
                    Spacer()
                    if model.funEnabled {
                        Text("自然分钟峰值  \(number(model.summary.peakKeysPerMinute)) 次/分")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(TrailStyle.muted)
                    }
                }.padding(.top, 9)
            }
            HStack(alignment: .top, spacing: 15) {
                panel("输入明细", eyebrow: "ACTIVITY NOTES") {
                    VStack(spacing: 17) {
                        detailRow("键盘活跃", value: duration(model.summary.keyboardActiveSeconds))
                        detailRow("鼠标活跃", value: duration(model.summary.mouseActiveSeconds))
                        if model.funEnabled {
                            detailRow("活跃期间平均", value: String(format: "%.1f 次/分", model.summary.averageKeysPerMinute))
                        }
                        detailRow("滚动量", value: String(format: "%.0f 单位", model.summary.scrollUnits))
                    }.padding(.top, 8)
                    Text("活跃时长是最近输入后 30 秒窗口的已观测部分；键鼠窗口重叠时只计一次。")
                        .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3).padding(.top, 15)
                }
                if model.funEnabled {
                  panel("常用按键 Top 10", eyebrow: "TOP TEN PHYSICAL KEYS", trailing: "按所选时段统计") {
                    if topKeys.isEmpty {
                        Text("第一个按键，会从这里开始。")
                            .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).frame(maxWidth: .infinity, minHeight: 154)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(Array(topKeys.prefix(10).enumerated()), id: \.element.key) { index, item in
                                HStack(spacing: 10) {
                                    Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(TrailStyle.muted)
                                    Text(displayKey(item.key)).font(.system(size: 11, weight: .semibold, design: .monospaced)).frame(minWidth: 34)
                                    GeometryReader { geo in
                                        Capsule().fill(TrailStyle.teal.opacity(0.12)).overlay(alignment: .leading) {
                                            Capsule().fill(TrailStyle.teal.opacity(0.65)).frame(width: max(2, geo.size.width * Double(item.value) / Double(topKeys.first?.value ?? 1)))
                                        }
                                    }.frame(height: 5)
                                    Text(number(item.value)).font(.system(size: 11, design: .monospaced)).frame(width: 48, alignment: .trailing)
                                }.frame(height: 23)
                            }
                        }.padding(.top, 6)
                    }
                  }
                }
            }
            if model.funEnabled {
                FunMetricsView(
                    metrics: model.funMetrics?.selectedInterval == model.selectedInterval ? model.funMetrics : nil,
                    isLoading: model.funMetricsLoading,
                    error: model.funMetricsError,
                    settings: model.funSettings,
                    isDemo: model.isDemo,
                    onSettingsChange: { model.updateFunSettings($0) },
                    onRetry: { model.refresh() }
                )
                InteractionMixCard(summary: model.summary)
                funPanel
            }
        }
    }

    private var keyboardPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            panel("你的键盘热力图", eyebrow: "A MAP OF YOUR HABITS", trailing: "\(number(model.summary.keyPresses)) 次敲击") {
                keyboardHeatmap.padding(.vertical, 18)
                HStack(spacing: 8) {
                    Text("较少").font(.system(size: 10))
                    ForEach(0..<6) { index in
                        RoundedRectangle(cornerRadius: 3).fill(TrailStyle.teal.opacity(0.08 + Double(index) * 0.16)).frame(width: 24, height: 10)
                    }
                    Text("较多").font(.system(size: 10))
                    Spacer()
                    Text("按所选时段相对频次着色").font(.system(size: 10))
                }.foregroundStyle(TrailStyle.muted)
                Text("布局用于展示物理键位。同名左右修饰键合并统计，图中显示相同频次。只保存每分钟各键次数，不保存顺序，也不还原文字；未显示的键仍计入总次数。")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4).padding(.top, 14)
            }
            panel("按键频次", eyebrow: "KEY FREQUENCY", trailing: "\(topKeys.count) 个键位") {
                if topKeys.isEmpty {
                    Text("这个时段还没有按键统计。")
                        .font(.system(size: 12)).foregroundStyle(TrailStyle.muted).frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                        ForEach(topKeys, id: \.key) { item in
                            HStack {
                                Text(displayKey(item.key)).font(.system(size: 12, weight: .medium, design: .monospaced))
                                Spacer()
                                Text(number(item.value)).font(.system(size: 12, design: .monospaced)).foregroundStyle(TrailStyle.teal)
                            }.padding(12).background(TrailStyle.paper, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }.padding(.top, 8)
                }
            }
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            panel("统计与权限", eyebrow: "YOU ARE IN CONTROL") {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.isDemo ? "演示模式不采集输入" : (model.permissionGranted ? "输入监控权限已允许" : "等待输入监控授权"))
                            .font(.system(size: 13, weight: .semibold))
                        Text("只有你主动开始后，键迹才会统计。暂停、锁屏和休眠期间不累计活跃时长。")
                            .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
                    }
                    Spacer()
                    if !model.isDemo { Button("打开系统权限设置") { model.openInputSettings() }.controlSize(.small) }
                }.padding(.vertical, 8)
                Divider().padding(.vertical, 12)
                Toggle(isOn: $model.funEnabled) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("给日常一点趣味").font(.system(size: 13, weight: .medium))
                        Text("显示 Top 10、操作能量、游戏距离、间隔 BPM、最高连击、千万次玩法估算、键盘热力图、周报与月报、同时段对比、键鼠窗口配合、成就和图谱。关闭后隐藏全部趣味展示，基础统计和采集继续。")
                            .font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
                    }
                }.toggleStyle(.switch)
            }
            RuntimeSettingsView(model: model)
            panel("隐私，写在明处", eyebrow: "PRIVATE BY DESIGN") {
                VStack(alignment: .leading, spacing: 16) {
                    privacyRow("keyboard", title: "默认记录统计，文字单独开关", body: "默认保存分钟计数与物理键位频次，不保存有序按键或剪贴板。可选文字归档需单独主动开启并授权，使用本机加密存储。")
                    privacyRow("cursorarrow", title: "光标轨迹不落盘", body: "只累加屏幕显示点（pt）距离，不保存坐标。pt 不是厘米、米或桌面移动距离。")
                    privacyRow("externaldrive", title: "本地优先，同步由你配置", body: "默认不上传；私有聚合同步与加密文字同步均需明确开启并配置你自己的服务。开机自启也默认关闭。关闭看板不停止后台；菜单栏退出键迹才停止全部进程。")
                }.padding(.top, 8)
            }
            panel("数据管理", eyebrow: "YOUR LOCAL ARCHIVE") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.dataPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(TrailStyle.muted)
                        .textSelection(.enabled).lineLimit(3)
                    HStack(spacing: 10) {
                        Button("打开数据文件夹", systemImage: "folder") { model.openDataFolder() }
                        Button("导出所选时段 CSV", systemImage: "square.and.arrow.up") { model.exportCSV() }.disabled(model.csvExporting || model.textExporting)
                            .disabled(model.selectedInterval.duration <= 0)
                    }.controlSize(.small)
                    Text("统计 CSV 导出与联合删除范围：\(model.rangeTitle)。可在总览中调整，历史范围精确到分钟。CSV 只含分钟聚合与单位说明；文字请在“文字”页单独导出。")
                        .font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
                    Divider()
                    HStack(spacing: 12) {
                        Button("删除所选统计与文字…", role: .destructive) { deletion = .selected(model.selectedInterval) }
                            .disabled(model.selectedInterval.duration <= 0)
                        Spacer()
                        Button("清空全部统计与文字…", role: .destructive) { deletion = .all }
                    }.controlSize(.small)
                    Text("联合删除同时清除所选分钟统计、按键频次、节奏记录与对应文字归档，并更新累计统计及成就。相应私有同步开启后，聚合与加密文字删除会分别传播。无法撤销；“文字”页的删除只影响文字。")
                        .font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
                }.padding(.top, 8)
            }
        }
    }

    private var funPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("把日常，留下形状。 ").font(.system(size: 20, weight: .medium, design: .serif))
                    Text("LITTLE MILESTONES, EVERY DAY").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.6).foregroundStyle(TrailStyle.muted)
                }
                Spacer()
                Button("导出图谱", systemImage: "square.and.arrow.up") { exportArt() }.controlSize(.small)
            }
            HStack(alignment: .top, spacing: 20) {
                TrailArtView(buckets: model.buckets, title: model.rangeTitle, isDemo: model.isDemo)
                    .frame(width: 220, height: 196).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 15) {
                    Text("累计敲击 · \(number(model.lifetime.keyPresses)) 次")
                        .font(.system(size: 12, weight: .semibold)).padding(.top, 4)
                    ForEach([(100_000, "初见锋芒"), (500_000, "指尖行者"), (1_000_000, "百万回响")], id: \.0) { threshold, title in
                        let achieved = model.lifetime.keyPresses >= threshold
                        HStack(spacing: 10) {
                            Image(systemName: achieved ? "seal.fill" : "seal")
                                .font(.system(size: 22)).foregroundStyle(achieved ? TrailStyle.orange : TrailStyle.muted.opacity(0.45))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(title).font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text("\(threshold / 10_000) 万次").font(.system(size: 10, design: .monospaced)).foregroundStyle(TrailStyle.muted)
                                }
                                GeometryReader { geo in
                                    Capsule().fill(TrailStyle.line.opacity(0.5)).overlay(alignment: .leading) {
                                        Capsule().fill(achieved ? TrailStyle.orange : TrailStyle.teal).frame(width: geo.size.width * min(1, Double(model.lifetime.keyPresses) / Double(threshold)))
                                    }
                                }.frame(height: 4)
                            }
                        }
                    }
                    Text("图谱由所选时段的分钟统计生成；相同数据拥有相同形状。")
                        .font(.system(size: 10)).foregroundStyle(TrailStyle.muted).lineSpacing(3)
                }
            }
        }.padding(22).background(TrailStyle.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(TrailStyle.teal.opacity(0.15), lineWidth: 1))
    }

    private var trendChart: some View {
        Chart {
            ForEach(trend) { point in
                BarMark(x: .value("时间", point.start), y: .value("次数", point.keys))
                    .foregroundStyle(TrailStyle.teal).position(by: .value("类型", "键盘"))
                    .cornerRadius(2)
                BarMark(x: .value("时间", point.start), y: .value("次数", point.clicks))
                    .foregroundStyle(TrailStyle.orange.opacity(0.8)).position(by: .value("类型", "鼠标"))
                    .cornerRadius(2)
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(TrailStyle.line.opacity(0.35))
                AxisValueLabel { if let date = value.as(Date.self) { Text(axisLabel(date)).font(.system(size: 9, design: .monospaced)) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(TrailStyle.line.opacity(0.45))
                AxisValueLabel().font(.system(size: 9, design: .monospaced))
            }
        }
        .chartYScale(domain: 0...max(5, (trend.map { max($0.keys, $0.clicks) }.max() ?? 0)))
        .frame(height: 210)
        .padding(.top, 20)
        .overlay {
            if trend.allSatisfy({ $0.keys == 0 && $0.clicks == 0 }) {
                Text("这个时段，还是一张白纸。")
                    .font(.system(size: 12)).foregroundStyle(TrailStyle.muted)
                    .padding(12).background(TrailStyle.surface.opacity(0.95), in: Capsule())
            }
        }
        .accessibilityLabel("所选时段键盘敲击与鼠标点击趋势")
    }

    private var keyboardHeatmap: some View {
        VStack(spacing: 5) {
            keyRow(["Esc", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"])
            keyRow(["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "Delete"])
            keyRow(["Tab", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "[", "]", "\\"])
            keyRow(["Caps", "A", "S", "D", "F", "G", "H", "J", "K", "L", ";", "'", "Return"])
            keyRow(["Shift", "Z", "X", "C", "V", "B", "N", "M", ",", ".", "/", "Shift"])
            keyRow(["Fn", "Ctrl", "Option", "Cmd", "Space", "Cmd", "Option", "←", "↑", "↓", "→"])
        }
    }

    private func keyRow(_ keys: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                let count = countForKey(key)
                let strength = count == 0 ? 0 : 0.17 + 0.76 * sqrt(Double(count) / Double(max(1, topKeys.first?.value ?? 1)))
                Text(displayKey(key))
                    .font(.system(size: key.count > 3 ? 8 : 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(strength > 0.55 ? TrailStyle.surface : TrailStyle.ink.opacity(0.8))
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .frame(minWidth: key == "Space" ? 160 : (key.count > 3 ? 42 : 24))
                    .background(count == 0 ? TrailStyle.paper : TrailStyle.teal.opacity(strength), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(TrailStyle.line.opacity(0.6), lineWidth: 0.7))
                    .help("\(displayKey(key))：\(number(count)) 次")
                    .accessibilityLabel("\(displayKey(key))，\(count) 次")
            }
        }
    }

    private var emptyNotice: some View {
        HStack(spacing: 13) {
            Image(systemName: "leaf").font(.system(size: 25, weight: .light)).foregroundStyle(TrailStyle.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text("从一枚按键，开始认识你的节奏。").font(.system(size: 13, weight: .medium))
                Text(model.isDemo ? "这个演示时段没有统计，可以换一个日期看看。" : "所选时段还没有数据。授权并开始统计后，真实活动会在这里汇成轨迹。")
                    .font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
            }
            Spacer()
        }.padding(17).background(TrailStyle.teal.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.shield").font(.system(size: 10))
            Text(model.isDemo ? "演示数据 · 与真实数据库隔离" : "本地优先 · 私有同步默认关闭")
            Spacer()
            if let updated = model.lastUpdated { Text("更新于 \(updated.formatted(.dateTime.hour().minute().second()))") }
        }.font(.system(size: 10)).foregroundStyle(TrailStyle.muted).padding(.top, 2)
    }

    private func panel<Content: View>(_ title: String, eyebrow: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.7).foregroundStyle(TrailStyle.muted)
            HStack {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10)).foregroundStyle(TrailStyle.muted) }
            }
            content()
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(TrailStyle.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(TrailStyle.line.opacity(0.55), lineWidth: 1))
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
            Text(error).textSelection(.enabled)
            Spacer()
            Button("重试") { model.refresh() }.controlSize(.small)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("关闭提示").accessibilityLabel("关闭错误提示")
        }.font(.system(size: 12)).foregroundStyle(TrailStyle.orange)
            .padding(14).background(TrailStyle.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(TrailStyle.muted)
            Spacer()
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced))
        }
    }

    private func chartLegend(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text(text).font(.system(size: 10)) }
            .foregroundStyle(TrailStyle.muted)
    }

    private func privacyRow(_ icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(TrailStyle.teal).frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(body).font(.system(size: 11)).foregroundStyle(TrailStyle.muted).lineSpacing(4)
            }
        }
    }

    private func deletionMessage(_ item: Deletion) -> String {
        switch item {
        case .all:
            return "将联合删除本地全部分钟统计、按键频次、节奏记录及文字归档，并清空累计成就进度、暂停采集。相应私有同步开启后，聚合与加密文字删除会分别传播到你的私有端。无法撤销。\(model.isDemo ? "当前仅为独立演示数据库。" : "")"
        case .selected(let interval):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return "将联合删除本地时间 \(formatter.string(from: interval.start)) 至 \(formatter.string(from: interval.end)) 的全部分钟统计（按键、鼠标、活跃时长、按键频次及节奏）和该时段文字归档；累计统计与成就同时更新。包含起点、不包含终点，覆盖完整分钟。相应私有同步开启后，聚合与加密文字删除会分别传播到你的私有端。无法撤销。\(model.isDemo ? "当前仅为独立演示数据库。" : "")"
        }
    }

    private var isEmpty: Bool { model.summary.keyPresses == 0 && model.summary.totalClicks == 0 && model.summary.mouseDistancePoints == 0 && model.summary.scrollUnits == 0 }
    private var topKeys: [(key: String, value: Int)] { model.summary.keyCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value } }
    private func number(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }
    private func duration(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)时 \((seconds % 3600) / 60)分" }
        if seconds >= 60 { return "\(seconds / 60)分 \(seconds % 60)秒" }
        return "\(seconds)秒"
    }
    private func compactDistance(_ points: Double) -> String {
        if points >= 1_000_000 { return String(format: "%.2fM", points / 1_000_000) }
        if points >= 10_000 { return String(format: "%.1fk", points / 1_000) }
        return String(format: "%.0f", points)
    }
    private func displayKey(_ key: String) -> String {
        switch key {
        case "Space": return "space"
        case "Return": return "↵"
        case "Delete": return "⌫"
        case "Shift": return "⇧"
        case "Cmd", "Command": return "⌘"
        case "Option": return "⌥"
        case "Ctrl", "Control": return "⌃"
        case "Caps", "CapsLock": return "⇪"
        case "Tab": return "⇥"
        default: return key
        }
    }
    private func countForKey(_ key: String) -> Int {
        let aliases: [String: [String]] = ["Cmd": ["Cmd", "Command", "Left Command", "Right Command"], "Ctrl": ["Ctrl", "Control", "Left Control", "Right Control"], "Option": ["Option", "Left Option", "Right Option"], "Shift": ["Shift", "Left Shift", "Right Shift"], "Caps": ["Caps", "CapsLock", "Caps Lock"], "Esc": ["Esc", "Escape"], "←": ["←", "Left"], "→": ["→", "Right"], "↑": ["↑", "Up"], "↓": ["↓", "Down"]]
        return (aliases[key] ?? [key]).reduce(0) { $0 + (model.summary.keyCounts[$1] ?? 0) }
    }

    private var trendComponent: Calendar.Component { model.overviewTrendPlan?.component ?? .hour }
    private var trend: [OverviewTrendPoint] { model.trendPoints }
    private func axisLabel(_ date: Date) -> String {
        switch trendComponent {
        case .year: return date.formatted(.dateTime.year())
        case .month: return date.formatted(.dateTime.month(.abbreviated))
        case .day: return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        default: return journalDate(date, "HH")
        }
    }

    private func exportArt() {
        let artwork = TrailArtView(buckets: model.buckets, title: model.rangeTitle, isDemo: model.isDemo)
            .frame(width: 900, height: 900)
        let renderer = ImageRenderer(content: artwork)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            exportError = "无法生成图像，请重试。"; return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "键迹图谱-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).png"
        panel.title = "导出键迹图谱"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url, options: .atomic) }
        catch { exportError = error.localizedDescription }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let icon: String
    let note: String
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(TrailStyle.muted)
                Spacer()
                Image(systemName: icon).font(.system(size: 16, weight: .regular)).foregroundStyle(accent)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 29, weight: .medium, design: .rounded)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
                Text(unit).font(.system(size: 10)).foregroundStyle(TrailStyle.muted)
            }
            Text(note).font(.system(size: 9)).foregroundStyle(TrailStyle.muted).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(TrailStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) { RoundedRectangle(cornerRadius: 1).fill(accent.opacity(0.65)).frame(width: 22, height: 2).padding(.leading, 18) }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(TrailStyle.line.opacity(0.6), lineWidth: 1))
    }
}

private struct TrailArtView: View {
    let buckets: [MinuteBucket]
    let title: String
    let isDemo: Bool

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / 220
            ZStack {
                TrailStyle.paper
                Canvas { context, size in
                    let center = CGPoint(x: size.width * 0.5, y: size.height * 0.43)
                    let radius = min(size.width, size.height) * 0.285
                    let groups = ringValues
                    let maximum = max(1, groups.max() ?? 1)
                    for index in 0..<72 {
                        let angle = Double(index) / 72 * .pi * 2 - .pi / 2
                        let value = groups[index]
                        let inner = radius * 0.54
                        let outer = inner + radius * (0.13 + 0.6 * sqrt(value / maximum))
                        var path = Path()
                        path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                        path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                        context.stroke(path, with: .color(index % 5 == 0 ? TrailStyle.orange.opacity(value > 0 ? 0.9 : 0.18) : TrailStyle.teal.opacity(value > 0 ? 0.85 : 0.16)), style: StrokeStyle(lineWidth: max(1, size.width / 145), lineCap: .round))
                    }
                    let circle = Path(ellipseIn: CGRect(x: center.x - radius * 0.37, y: center.y - radius * 0.37, width: radius * 0.74, height: radius * 0.74))
                    context.stroke(circle, with: .color(TrailStyle.teal.opacity(0.18)), lineWidth: max(0.6, size.width / 700))
                }
                VStack(spacing: 4 * scale) {
                    Spacer()
                    Text("键 迹").font(.system(size: 14 * scale, weight: .medium, design: .serif)).tracking(2 * scale)
                    Text(title).font(.system(size: max(7, 7 * scale), design: .monospaced)).lineLimit(2).multilineTextAlignment(.center)
                    Text(isDemo ? "DEMO DATA · 本地演示" : "A LITTLE TRACE OF YOUR DAY")
                        .font(.system(size: max(5, 5.5 * scale), design: .monospaced)).tracking(0.5 * scale)
                        .foregroundStyle(isDemo ? TrailStyle.orange : TrailStyle.muted)
                }.padding(.horizontal, 12 * scale).padding(.bottom, 14 * scale)
            }.foregroundStyle(TrailStyle.ink)
        }
    }

    private var ringValues: [Double] {
        let sorted = buckets.sorted { $0.start < $1.start }
        guard let first = sorted.first?.start, let last = sorted.last?.start else { return Array(repeating: 0, count: 72) }
        let duration = max(60, last.timeIntervalSince(first) + 60)
        var values = Array(repeating: 0.0, count: 72)
        for bucket in sorted {
            let index = min(71, max(0, Int(bucket.start.timeIntervalSince(first) / duration * 72)))
            values[index] += Double(bucket.summary.keyPresses + bucket.summary.totalClicks) + sqrt(max(0, bucket.summary.mouseDistancePoints))
        }
        return values
    }
}

private struct JournalToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? TrailStyle.teal : TrailStyle.line)
                .frame(width: 44, height: 24)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 20, height: 20).padding(2)
                }
        }.buttonStyle(.plain)
            .accessibilityLabel("趣味面板")
            .accessibilityValue(configuration.isOn ? "开启" : "关闭")
            .help(configuration.isOn ? "收起趣味面板" : "展开趣味面板")
    }
}
