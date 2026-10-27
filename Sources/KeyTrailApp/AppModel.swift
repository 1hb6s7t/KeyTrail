import AppKit
import Combine
import Foundation
import KeyTrailCore
import KeyTrailIPC
import UniformTypeIdentifiers

enum RangeMode: String, CaseIterable, Identifiable {
    case today, day, week, month, year, custom
    var id: String { rawValue }
    var title: String { switch self { case .today: "今日"; case .day: "按日"; case .week: "本周"; case .month: "按月"; case .year: "按年"; case .custom: "自定义" } }
}

/// All socket operations, including exports and mutations, share one serial queue.
/// The dashboard never opens the database or owns the input monitor.
private final class DashboardRPC {
    private let queue = DispatchQueue(label: "com.auriel.keytrail.dashboard.rpc", qos: .userInitiated)
    private let client: RuntimeClient

    init(isDemo: Bool, directory: URL? = nil) {
        client = directory.map { RuntimeClient(socketURL: $0.appendingPathComponent("engine.sock")) } ?? RuntimeClient(isDemo: isDemo)
    }

    func perform<T>(_ work: @escaping (RuntimeClient) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [client] in
                do { continuation.resume(returning: try work(client)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }
}

private struct DashboardSnapshot {
    var status: RuntimeStatus
    var summary: ActivitySummary?
    var buckets: [MinuteBucket]?
    var trendPlan: OverviewTrendPlan?
    var trendPoints: [OverviewTrendPoint] = []
    var trendError: String?
    var lifetime: ActivitySummary?
}

private enum PeriodSnapshot {
    case week(WeeklyRhythm)
    case month(MonthlyRhythm)
}

private final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var publishing = false
    @discardableResult func cancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !publishing else { return false }
        cancelled = true; return true
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw RuntimeError("导出已取消，未发布部分文件。") }
    }
    func beginPublish() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw RuntimeError("导出已取消，未发布部分文件。") }
        publishing = true
    }
}

private struct TextPagePosition {
    var cursor: TextScanCursor?
    var scannedBefore: Int = 0
    var matchedBefore: Int = 0
}

private func textPageRequest(range: DateInterval, keyword: String, cursor: TextScanCursor?) throws -> [String: Any] {
    var request: [String: Any] = ["op": "textSearchPage", "start": range.start.timeIntervalSince1970,
                                 "end": range.end.timeIntervalSince1970, "keyword": keyword, "limit": 100]
    if let cursor { request["cursor"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cursor)) }
    return request
}

private func queryFunMetrics(_ client: RuntimeClient, range: DateInterval, now: Date, calendar: Calendar, settings: FunSettings) throws -> FunMetrics {
    let start = range.start.timeIntervalSince1970
    let end = max(range.start, min(range.end, now)).timeIntervalSince1970
    let selected = try DashboardRPC.decode(ActivitySummary.self, from: client.request(["op": "summary", "start": start, "end": end]))
    let timing = try DashboardRPC.decode(TimingInsights.self, from: client.request(["op": "insights", "start": start, "end": end]))
    let lifetime = try DashboardRPC.decode(ActivitySummary.self, from: client.request(["op": "summary", "start": 0, "end": now.timeIntervalSince1970]))
    let day = calendar.startOfDay(for: now)
    let historyRanges = FunMetrics.historyRanges(now: now, calendar: calendar)
    let historyStart = historyRanges.first?.start ?? day
    let historyQuery: [String: Any] = ["start": historyStart.timeIntervalSince1970, "end": day.timeIntervalSince1970]
    // Calendar-day summaries avoid assigning an elapsed-hour bucket that crosses
    // local midnight to the wrong date after a fractional-hour DST transition.
    let days = historyRanges.map { interval in
        return ["start": interval.start.timeIntervalSince1970, "end": interval.end.timeIntervalSince1970]
    }
    let history = try DashboardRPC.decode([MinuteBucket].self, from: client.request(["op": "summaries", "ranges": days]))
    let recent = try DashboardRPC.decode(ActivitySummary.self, from: client.request(historyQuery.merging(["op": "summary"]) { _, next in next }))
    return FunMetrics(summary: selected, lifetimeKeyPresses: lifetime.keyPresses, timing: timing,
                      selectedInterval: range, recentHistory: history, settings: settings,
                      lifetimeMouseDistancePoints: lifetime.mouseDistancePoints,
                      lifetimeKeyCounts: lifetime.keyCounts, recentKeyCounts: recent.keyCounts, now: now, calendar: calendar)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var summary = ActivitySummary()
    @Published var lifetime = ActivitySummary()
    @Published var buckets: [MinuteBucket] = []
    @Published var overviewTrendPlan: OverviewTrendPlan?
    @Published var trendPoints: [OverviewTrendPoint] = []
    @Published var trendError: String?
    @Published var rangeMode: RangeMode = .today
    @Published var selectedDate = Date()
    @Published var customStart = Calendar.current.startOfDay(for: Date())
    @Published var customEnd = Date()
    @Published var funEnabled: Bool { didSet { defaults?.set(funEnabled, forKey: "funEnabled") } }
    @Published var isMonitoring = false
    @Published private(set) var collectorPID: Int32?
    @Published var permissionGranted = false
    @Published var statusText = "正在连接本地 Rust 后台…"
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?
    @Published var insightsAnchor = Date()
    @Published var insightPeriod: InsightPeriod = .week
    @Published var weeklyRhythm: WeeklyRhythm?
    @Published var monthlyRhythm: MonthlyRhythm?
    @Published var periodFunMetrics: FunMetrics?
    @Published var periodTextMetrics: ArchivedTextMetrics?
    @Published var insightsLoading = false
    @Published var insightsError: String?
    @Published var reportNotice: String?
    @Published var dailyComparison: DailyComparison?
    @Published var comparisonLoading = false
    @Published var comparisonError: String?
    @Published var funSettings = FunSettings()
    @Published var funMetrics: FunMetrics?
    @Published var funMetricsLoading = false
    @Published var funMetricsError: String?
    @Published var runtimeDetails: RuntimeDetails?
    @Published var runtimeSettingsLoading = false
    @Published var runtimeSettingsError: String?
    @Published var preferencesSaveState: RuntimePreferencesSaveState = .idle
    @Published var textHistory: TextScanPage?
    @Published var textHistoryLoading = false
    @Published var textHistoryError: String?
    @Published var textKeyword = ""
    @Published var textRecordingStatus: TextRecordingStatus?
    @Published var textMetrics: ArchivedTextMetrics?
    @Published var textHistoryPageIndex = 0
    @Published var textScannedRecords = 0
    @Published var textMatchedCount = 0
    @Published var textExporting = false
    @Published var textExportNotice: String?
    @Published var csvExporting = false
    @Published var csvExportNotice: String?
    @Published var csvExportFailed = false
    let isDemo: Bool
    let dataPath: String
    private let defaults: UserDefaults?
    private let rpc: DashboardRPC
    private var timer: Timer?
    private var dashboardVisible = false
    private var stopped = false
    private var paused = false
    private var generation: UInt64 = 0
    private var refreshInFlight = false
    private var pendingRefresh = false
    private var pendingForce = false
    private var controlsInFlight = 0
    private var lastLifetimeRefresh = Date.distantPast
    private var lastRequestedRange: DateInterval?
    private var lastSelectedRefresh = Date.distantPast
    private var queryError: String?
    private var insightsVisible = false
    private var insightsGeneration: UInt64 = 0
    private var insightsInFlight = false
    private var insightsPending = false
    private var lastInsightsRefresh = Date.distantPast
    private var overviewVisible = false
    private var comparisonGeneration: UInt64 = 0
    private var comparisonInFlight = false
    private var comparisonPending = false
    private var lastComparisonAttempt = Date.distantPast
    private var comparisonDay: Date?
    private var comparisonTimeZone: String?
    private var funGeneration: UInt64 = 0
    private var funInFlight = false
    private var funPending = false
    private var lastFunRefresh = Date.distantPast
    private var lastFunRange: DateInterval?
    private var lastFunDay: Date?
    private var lastRuntimeRefresh = Date.distantPast
    private var textGeneration: UInt64 = 0
    private var textInFlight = false
    private var textPending = false
    private var textSnapshot: (range: DateInterval, keyword: String)?
    private var textPagePositions: [TextPagePosition] = [.init(cursor: nil)]
    private var textExportCancellation: ExportCancellation?
    private var csvExportCancellation: ExportCancellation?
    private var csvExportID: UUID?
    var isPaused: Bool { paused }

    init(isDemo: Bool = CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier == "com.auriel.keytrail.preview.dashboard") {
        self.isDemo = isDemo
        // A fixture dashboard must use the fixture socket and never read or write
        // the user's persisted dashboard settings. Normal launches are unchanged.
        var testDirectory: URL?
        let directoryOptions = CommandLine.arguments.enumerated().filter { $0.element.hasPrefix("--test-directory") }
        if let option = directoryOptions.first {
            let path: String?
            if option.element == "--test-directory", option.offset + 1 < CommandLine.arguments.count {
                path = CommandLine.arguments[option.offset + 1]
            } else if option.element.hasPrefix("--test-directory=") {
                path = String(option.element.dropFirst("--test-directory=".count))
            } else { path = nil }
            guard isDemo, directoryOptions.count == 1, let path, path.hasPrefix("/") else {
                fputs("--test-directory requires --demo and one absolute directory path.\n", stderr)
                exit(64)
            }
            testDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        defaults = testDirectory != nil ? nil : (isDemo ? UserDefaults(suiteName: "com.auriel.keytrail.demo")! :
            (Bundle.main.bundleIdentifier == "com.auriel.keytrail.journal.dashboard" ? UserDefaults(suiteName: "com.auriel.keytrail.dashboard")! : .standard))
        funEnabled = defaults?.object(forKey: "funEnabled") as? Bool ?? true
        if let saved = defaults?.data(forKey: "funSettings"), let value = try? JSONDecoder().decode(FunSettings.self, from: saved), value.validationError == nil { funSettings = value }
        rpc = DashboardRPC(isDemo: isDemo, directory: testDirectory)
        dataPath = (testDirectory?.appendingPathComponent("activity.sqlite") ?? RuntimePaths.databaseURL(isDemo: isDemo)).path
        if isDemo {
            selectedDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            insightsAnchor = selectedDate
            rangeMode = .day
        }
    }

    var selectedInterval: DateInterval {
        let cal = Calendar.current
        switch rangeMode {
        case .today: return cal.dateInterval(of: .day, for: Date())!
        case .day: return cal.dateInterval(of: .day, for: selectedDate)!
        case .week:
            var weekCalendar = cal
            weekCalendar.firstWeekday = 2
            return weekCalendar.dateInterval(of: .weekOfYear, for: selectedDate)!
        case .month: return cal.dateInterval(of: .month, for: selectedDate)!
        case .year: return cal.dateInterval(of: .year, for: selectedDate)!
        case .custom:
            let start = Date(timeIntervalSince1970: floor(customStart.timeIntervalSince1970 / 60) * 60)
            let end = Date(timeIntervalSince1970: floor(customEnd.timeIntervalSince1970 / 60) * 60)
            return DateInterval(start: start, end: max(start, end))
        }
    }

    var rangeTitle: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = rangeMode == .month ? "yyyy 年 M 月" : rangeMode == .year ? "yyyy 年" : "yyyy 年 M 月 d 日"
        if rangeMode == .today { return "今日 · \(formatter.string(from: Date()))" }
        if rangeMode == .week {
            formatter.dateFormat = "M月d日"
            let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: selectedInterval.end)!
            return "\(formatter.string(from: selectedInterval.start)) — \(formatter.string(from: lastDay))"
        }
        if rangeMode == .custom {
            formatter.dateFormat = "MM/dd HH:mm"
            return "\(formatter.string(from: selectedInterval.start)) — \(formatter.string(from: selectedInterval.end))"
        }
        return formatter.string(from: selectedDate)
    }

    func setDashboardVisible(_ visible: Bool) {
        guard !stopped, dashboardVisible != visible else { return }
        dashboardVisible = visible
        timer?.invalidate(); timer = nil
        if visible {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshStatistics(force: false); self?.refreshInsightsIfNeeded(); self?.refreshComparisonIfNeeded()
                    self?.refreshFunMetrics(force: false)
                    if let self, self.runtimeDetails != nil, Date().timeIntervalSince(self.lastRuntimeRefresh) >= 6 { self.refreshRuntimeDetails() }
                }
            }
        } else {
            generation &+= 1
            pendingRefresh = false; pendingForce = false
            insightsGeneration &+= 1; insightsPending = false; insightsLoading = false
            comparisonGeneration &+= 1; comparisonPending = false; comparisonLoading = false
            funGeneration &+= 1; funPending = false; funMetricsLoading = false
            textGeneration &+= 1; textPending = false; textHistoryLoading = false
        }
    }

    func refresh() {
        generation &+= 1
        refreshStatistics(force: true)
        refreshInsights()
        refreshComparison()
        funGeneration &+= 1; funMetrics = nil
        refreshFunMetrics()
    }

    private func refreshStatistics(force: Bool) {
        guard !stopped, dashboardVisible else { return }
        guard !refreshInFlight, controlsInFlight == 0 else {
            pendingRefresh = true; pendingForce = pendingForce || force
            return
        }
        let range = selectedInterval
        guard range.duration > 0 else {
            queryError = "结束时间必须晚于开始时间（精确到分钟）。"; errorMessage = queryError
            summary = ActivitySummary(); buckets = []; trendPoints = []; overviewTrendPlan = nil; trendError = nil; return
        }
        let now = Date()
        let requestGeneration = generation
        let calendar = Calendar.current, preferMonthly = rangeMode == .year
        let querySelected = DashboardRefreshPolicy.selectedRangeNeedsRefresh(range, previousRange: lastRequestedRange,
            refreshedAt: lastSelectedRefresh, now: now, force: force)
        let queryLifetime = force || now.timeIntervalSince(lastLifetimeRefresh) >= 30
        let start = range.start.timeIntervalSince1970
        let end = max(range.start, min(range.end, now)).timeIntervalSince1970
        refreshInFlight = true
        Task {
            defer { refreshInFlight = false; drainRefresh() }
            do {
                let result = try await rpc.perform { client in
                    var snapshot = DashboardSnapshot(status: try client.status())
                    if querySelected {
                        snapshot.summary = try DashboardRPC.decode(ActivitySummary.self, from: client.request(["op": "summary", "start": start, "end": end]))
                        // Summary remains usable if calendar planning or trend I/O fails.
                        do {
                            let plan = try OverviewTrendPlan(interval: range, observedThrough: now, calendar: calendar, preferMonthly: preferMonthly)
                            let values = plan.segments.isEmpty ? [] : try DashboardRPC.decode([MinuteBucket].self, from: client.request(["op": "trend", "ranges": plan.queryRanges]))
                            snapshot.trendPoints = try plan.points(for: values)
                            snapshot.trendPlan = plan; snapshot.buckets = values
                        } catch { snapshot.trendError = "趋势读取失败：\(error.localizedDescription)"; snapshot.buckets = [] }
                    }
                    if queryLifetime {
                        snapshot.lifetime = try DashboardRPC.decode(ActivitySummary.self, from: client.request(["op": "summary", "start": 0.0, "end": now.timeIntervalSince1970]))
                    }
                    return snapshot
                }
                guard requestGeneration == generation, dashboardVisible, !stopped else { return }
                apply(result.status)
                if let value = result.summary {
                    summary = value; buckets = result.buckets ?? []
                    overviewTrendPlan = result.trendPlan; trendPoints = result.trendPoints; trendError = result.trendError
                    lastRequestedRange = range; lastSelectedRefresh = now; lastUpdated = now
                }
                if let value = result.lifetime { lifetime = value; lastLifetimeRefresh = now }
                if errorMessage == queryError { errorMessage = nil }
                queryError = nil
            } catch {
                guard requestGeneration == generation, dashboardVisible, !stopped else { return }
                statusText = "本地后台连接失败"
                queryError = "读取统计失败：\(error.localizedDescription)。请从菜单栏打开或重新启动键迹。"
                errorMessage = queryError
            }
        }
    }

    private func apply(_ status: RuntimeStatus) {
        if let pid = Int32(exactly: status.pid), pid > 0 { collectorPID = pid }
        isMonitoring = status.monitoring
        permissionGranted = status.permissionGranted
        paused = status.paused
        statusText = status.statusText
    }

    private func drainRefresh() {
        guard pendingRefresh, !stopped, dashboardVisible else { return }
        let force = pendingForce
        pendingRefresh = false; pendingForce = false
        refreshStatistics(force: force)
    }

    private func control(_ operation: [String: Any], failure: String, pauseFirst: Bool = false) {
        guard !stopped else { return }
        generation &+= 1
        let controlGeneration = generation
        controlsInFlight += 1
        Task {
            defer { controlsInFlight -= 1; refresh() }
            do {
                let status = try await rpc.perform { client in
                    if pauseFirst { _ = try client.request(["op": "pause"]) }
                    _ = try client.request(operation)
                    return try client.status()
                }
                guard !stopped, controlGeneration == generation else { return }
                apply(status)
                errorMessage = nil; queryError = nil
            } catch {
                guard !stopped else { return }
                errorMessage = "\(failure)：\(error.localizedDescription)"
            }
        }
    }

    func startMonitoring() {
        guard !isDemo else { return }
        // This flag only comes from the user's explicit start/authorize action.
        // The resident agent requests its own input-monitoring permission.
        control(["op": "start", "requestPermission": true], failure: "启动记录失败")
    }

    func pause(minutes: Int? = nil) {
        guard !isDemo else { return }
        var operation: [String: Any] = ["op": "pause"]
        if let minutes { operation["minutes"] = minutes }
        control(operation, failure: "暂停失败")
    }

    func resume() { startMonitoring() }

    /// Closing this process affects only dashboard resources, never collection.
    func shutdown() {
        textExportCancellation?.cancel()
        csvExportCancellation?.cancel()
        stopped = true; dashboardVisible = false; generation &+= 1
        insightsGeneration &+= 1; insightsPending = false
        comparisonGeneration &+= 1; comparisonPending = false
        funGeneration &+= 1; funPending = false; textGeneration &+= 1; textPending = false
        timer?.invalidate(); timer = nil
        pendingRefresh = false; pendingForce = false
    }

    func setInsightsVisible(_ visible: Bool) {
        guard insightsVisible != visible else { return }
        insightsVisible = visible
        insightsGeneration &+= 1
        insightsPending = false
        if visible { refreshInsights() } else { insightsLoading = false }
    }

    private func refreshInsightsIfNeeded() {
        guard !insightsInFlight, DashboardRefreshPolicy.isDue(since: lastInsightsRefresh, at: Date(),
            interval: DashboardRefreshPolicy.historicalInterval) else { return }
        refreshInsights()
    }

    func refreshInsights() {
        guard !stopped, dashboardVisible, insightsVisible, funEnabled else { return }
        insightsGeneration &+= 1
        if insightsInFlight { insightsPending = true; weeklyRhythm = nil; monthlyRhythm = nil; periodFunMetrics = nil; periodTextMetrics = nil; insightsLoading = true; return }
        let requestGeneration = insightsGeneration
        let anchor = insightsAnchor, now = Date(), calendar = Calendar.current, demo = isDemo, period = insightPeriod, settings = funSettings
        lastInsightsRefresh = now
        insightsInFlight = true; insightsLoading = true; insightsError = nil; reportNotice = nil; weeklyRhythm = nil; monthlyRhythm = nil; periodFunMetrics = nil; periodTextMetrics = nil
        Task {
            defer {
                insightsInFlight = false
                if requestGeneration == insightsGeneration { insightsLoading = false }
                if insightsPending { insightsPending = false; refreshInsights() }
            }
            do {
                let (rhythm, metrics, textMetrics): (PeriodSnapshot, FunMetrics, ArchivedTextMetrics) = try await rpc.perform { client in
                    let week = period == .week ? WeeklyRhythmPlan(anchor: anchor, observedThrough: now, calendar: calendar) : nil
                    let month = period == .month ? MonthlyRhythmPlan(anchor: anchor, observedThrough: now, calendar: calendar) : nil
                    let start = week?.weekStart ?? month!.start
                    let segments = week?.querySegments ?? month!.querySegments
                    guard start.timeIntervalSince1970 >= 0 else { throw RuntimeError("请选择 1970 年之后的完整自然周或自然月。") }
                    let ranges = segments.map { ["start": $0.start.timeIntervalSince1970, "end": $0.end.timeIntervalSince1970] }
                    let buckets: [MinuteBucket]
                    if ranges.isEmpty { buckets = [] }
                    else { buckets = try DashboardRPC.decode([MinuteBucket].self, from: client.request(["op": period == .week ? "timeline" : "summaries", "ranges": ranges])) }
                    let end = week?.weekEnd ?? month!.end
                    let metrics = try queryFunMetrics(client, range: DateInterval(start: start, end: end), now: now, calendar: calendar, settings: settings)
                    let textMetrics = try DashboardRPC.decode(ArchivedTextMetrics.self, from: client.request(["op": "textMetrics", "start": start.timeIntervalSince1970, "end": max(start, min(end, now)).timeIntervalSince1970]))
                    if let week { return (.week(try WeeklyRhythm(plan: week, buckets: buckets, isDemo: demo)), metrics, textMetrics) }
                    return (.month(try MonthlyRhythm(plan: month!, buckets: buckets, isDemo: demo)), metrics, textMetrics)
                }
                guard requestGeneration == insightsGeneration, dashboardVisible, insightsVisible, !stopped else { return }
                switch rhythm { case .week(let value): weeklyRhythm = value; case .month(let value): monthlyRhythm = value }
                periodFunMetrics = metrics
                periodTextMetrics = textMetrics
                lastInsightsRefresh = now
            } catch {
                guard requestGeneration == insightsGeneration, dashboardVisible, insightsVisible, !stopped else { return }
                insightsError = "\(period == .week ? "周" : "月")统计读取失败：\(error.localizedDescription)"
            }
        }
    }

    func copyWeeklyReport() {
        guard let report = selectedReport, !insightsLoading, insightsError == nil else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(report.text, forType: .string) { reportNotice = "\(report.label)已复制。" }
        else { reportNotice = "复制失败，请重试。" }
    }

    func exportWeeklyReport() {
        guard let report = selectedReport, !insightsLoading, insightsError == nil else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = Calendar.current.timeZone
        panel.nameFieldStringValue = "KeyTrail-\(report.slug)-\(formatter.string(from: report.start))\(isDemo ? "-demo" : "").txt"
        panel.title = "导出本地\(report.label)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PrivateFile.write(Data(report.text.utf8), to: url)
            reportNotice = "\(report.label)已导出：\(url.lastPathComponent)"
        } catch { reportNotice = "\(report.label)导出失败：\(error.localizedDescription)" }
    }

    var selectedReportText: String {
        let base = insightPeriod == .week ? weeklyRhythm?.report : monthlyRhythm?.report
        guard let base else { return "" }
        let textSummary = periodTextMetrics.map { value in
            let average = value.averageCharactersPerActiveMinute.map { String(format: "%.1f 字符/归档活跃分钟", $0) } ?? "不适用"
            return "\n\n可选文字归档摘要（不含正文）\n同报告范围已归档 \(value.totalCharacters) 字符，覆盖 \(value.recordedMinutes) 个有归档分钟。\n归档窗口平均：\(average)；自然分钟归档峰值：\(value.peakCharactersPerMinute) 字符。\n只计算已保存片段，包含可记录的粘贴；没有记录不代表没有输入。字符速度与物理按键速度及间隔 BPM 不同。"
        } ?? ""
        return base + (periodFunMetrics.map { "\n\n" + $0.reportAppendix(calendar: Calendar.current) } ?? "") + textSummary
    }

    private var selectedReport: (text: String, start: Date, label: String, slug: String)? {
        switch insightPeriod {
        case .week: return weeklyRhythm.map { (selectedReportText, $0.weekStart, "周报", "week") }
        case .month: return monthlyRhythm.map { (selectedReportText, $0.start, "月报", "month") }
        }
    }

    func setOverviewVisible(_ visible: Bool) {
        overviewVisible = visible
        comparisonGeneration &+= 1; comparisonPending = false
        funGeneration &+= 1; funPending = false
        if visible { refreshComparison(); refreshFunMetrics() }
        else { comparisonLoading = false; funMetricsLoading = false }
    }

    func updateFunSettings(_ value: FunSettings) {
        if let error = value.validationError { funMetricsError = error; return }
        funSettings = value
        if let data = try? JSONEncoder().encode(value) { defaults?.set(data, forKey: "funSettings") }
        funGeneration &+= 1; refreshFunMetrics()
        if insightsVisible { refreshInsights() }
    }

    func refreshFunMetrics(force: Bool = true) {
        guard !stopped, dashboardVisible, overviewVisible, funEnabled else { return }
        let range = selectedInterval, now = Date(), calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let changed = lastFunRange != range || lastFunDay != day
        guard force || changed || now.timeIntervalSince(lastFunRefresh) >= 30 else { return }
        if funInFlight {
            if force || changed { funGeneration &+= 1; funPending = true; funMetrics = nil }
            return
        }
        funGeneration &+= 1
        let run = funGeneration, settings = funSettings
        funInFlight = true; funMetricsLoading = funMetrics == nil; funMetricsError = nil
        lastFunRefresh = now; lastFunRange = range; lastFunDay = day
        Task {
            defer {
                funInFlight = false
                if run == funGeneration { funMetricsLoading = false }
                if funPending { funPending = false; refreshFunMetrics() }
            }
            do {
                let value = try await rpc.perform { client in
                    try queryFunMetrics(client, range: range, now: now, calendar: calendar, settings: settings)
                }
                guard run == funGeneration, !stopped, dashboardVisible, overviewVisible, funEnabled else { return }
                funMetrics = value
            } catch {
                guard run == funGeneration, !stopped else { return }
                funMetricsError = "趣味统计读取失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshRuntimeDetails() {
        guard !stopped, !runtimeSettingsLoading else { return }
        runtimeSettingsLoading = true; lastRuntimeRefresh = Date()
        Task {
            defer { runtimeSettingsLoading = false }
            do {
                let value = try await rpc.perform { client in try DashboardRPC.decode(RuntimeDetails.self, from: client.request(["op": "preferences"])) }
                guard !stopped else { return }
                runtimeDetails = value; runtimeSettingsError = nil
            } catch { if !stopped { runtimeSettingsError = error.localizedDescription } }
        }
    }

    private func runtimeOperation(_ operation: [String: Any], expectedPreferences: RuntimePreferences? = nil,
                                  reportSaveResult: Bool = false) {
        guard !stopped, !runtimeSettingsLoading else {
            if reportSaveResult { preferencesSaveState = .failed("后台正在处理其他请求，请稍后再保存。") }
            return
        }
        runtimeSettingsLoading = true
        if reportSaveResult { preferencesSaveState = .saving }
        Task {
            defer { runtimeSettingsLoading = false; lastRuntimeRefresh = .distantPast }
            do {
                let value = try await rpc.perform { client in
                    _ = try client.request(operation)
                    return try DashboardRPC.decode(RuntimeDetails.self, from: client.request(["op": "preferences"]))
                }
                guard !stopped else { return }
                runtimeDetails = value; runtimeSettingsError = nil
                if let expectedPreferences { try RuntimePreferencesSubmission.confirm(expectedPreferences, actual: value.preferences) }
                if reportSaveResult { preferencesSaveState = .saved }
            } catch {
                if !stopped {
                    runtimeSettingsError = error.localizedDescription
                    if reportSaveResult { preferencesSaveState = .failed(error.localizedDescription) }
                }
            }
        }
    }

    func clearPreferencesSaveFeedback() {
        if !preferencesSaveState.isSaving { preferencesSaveState = .idle }
    }

    func updateRuntimePreferences(_ preferences: RuntimePreferences, reportSaveResult: Bool = false) {
        do {
            let validated = try RuntimePreferencesSubmission.validate(preferences, current: runtimeDetails, isDemo: isDemo)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(validated))
            runtimeOperation(["op": "setPreferences", "preferences": object,
                              "requestTextPermission": validated.textRecordingEnabled && runtimeDetails?.preferences.textRecordingEnabled != true],
                             expectedPreferences: validated, reportSaveResult: reportSaveResult)
        } catch {
            runtimeSettingsError = error.localizedDescription
            if reportSaveResult { preferencesSaveState = .failed(error.localizedDescription) }
        }
    }

    func configurePrivateSync(endpoint: String, token: String, deviceId: String, enabled: Bool) {
        runtimeOperation(["op": "configureSync", "endpoint": endpoint, "token": token, "deviceId": deviceId, "enabled": enabled])
    }
    func syncNow() { runtimeOperation(["op": "syncNow"]) }

    func refreshTextHistory(resetPage: Bool = true, targetPage: Int? = nil) {
        guard !stopped else { return }
        if textInFlight {
            if resetPage { textGeneration &+= 1; textPending = true; textHistory = nil; textMetrics = nil; textHistoryLoading = true }
            return
        }
        textGeneration &+= 1
        if resetPage || textSnapshot == nil {
            let selected = selectedInterval
            textSnapshot = (DateInterval(start: selected.start, end: max(selected.start, min(selected.end, Date()))), textKeyword)
            textPagePositions = [.init(cursor: nil)]
            textHistoryPageIndex = 0; textScannedRecords = 0; textMatchedCount = 0
        }
        let run = textGeneration, range = textSnapshot!.range, keyword = textSnapshot!.keyword
        let pageIndex = resetPage ? 0 : (targetPage ?? textHistoryPageIndex + 1)
        guard textPagePositions.indices.contains(pageIndex) else { return }
        let position = textPagePositions[pageIndex]
        let expectedRevision = resetPage ? nil : textHistory?.snapshotRevision
        if resetPage { textHistory = nil; textMetrics = nil }
        textInFlight = true; textHistoryLoading = true; textHistoryError = nil
        Task {
            defer {
                textInFlight = false
                if run == textGeneration { textHistoryLoading = false }
                if textPending { textPending = false; refreshTextHistory() }
            }
            do {
                let (status, page, metrics) = try await rpc.perform { client in
                    let status = try DashboardRPC.decode(TextRecordingStatus.self, from: client.request(["op": "textStatus"]))
                    let page = try DashboardRPC.decode(TextScanPage.self, from: client.request(textPageRequest(range: range, keyword: keyword, cursor: position.cursor)))
                    if let expectedRevision, page.snapshotRevision != expectedRevision { throw RuntimeError("文字归档已变化，请重新搜索。") }
                    let metrics = try DashboardRPC.decode(ArchivedTextMetrics.self, from: client.request(["op": "textMetrics", "start": range.start.timeIntervalSince1970, "end": range.end.timeIntervalSince1970]))
                    _ = try client.request(["op": "textValidateSnapshot", "snapshotRevision": page.snapshotRevision])
                    return (status, page, metrics)
                }
                guard !stopped, run == textGeneration else { return }
                textRecordingStatus = status
                textMetrics = metrics
                textHistory = page; textHistoryPageIndex = pageIndex
                textScannedRecords = position.scannedBefore + page.scannedRecords
                textMatchedCount = position.matchedBefore + page.matchedCount
                if let next = page.nextCursor, page.hasMore {
                    let nextPosition = TextPagePosition(cursor: next, scannedBefore: textScannedRecords, matchedBefore: textMatchedCount)
                    if textPagePositions.count > pageIndex + 1 { textPagePositions[pageIndex + 1] = nextPosition }
                    else { textPagePositions.append(nextPosition) }
                }
            } catch { if !stopped, run == textGeneration { textHistoryError = error.localizedDescription } }
        }
    }
    func loadMoreTextHistory() { guard !textHistoryLoading, textHistory?.hasMore == true else { return }; refreshTextHistory(resetPage: false) }
    func previousTextHistoryPage() { guard !textHistoryLoading, textHistoryPageIndex > 0 else { return }; refreshTextHistory(resetPage: false, targetPage: textHistoryPageIndex - 1) }

    private func textOperation(_ object: [String: Any]) {
        guard !stopped else { return }
        textGeneration &+= 1; textHistoryLoading = true
        let run = textGeneration
        Task {
            do { _ = try await rpc.perform { try $0.request(object) }; if !stopped, run == textGeneration { refreshTextHistory() } }
            catch { if !stopped, run == textGeneration { textHistoryLoading = false; textHistoryError = error.localizedDescription } }
        }
    }
    func deleteTextRecords(_ ids: [String]) { textOperation(["op": "textDelete", "ids": ids]) }
    func deleteTextHistory(in interval: DateInterval) {
        textOperation(["op": "textDelete", "start": interval.start.timeIntervalSince1970, "end": interval.end.timeIntervalSince1970])
    }
    func copyTextViewingKey() {
        Task {
            do {
                let key = try await rpc.perform { try $0.request(["op": "textViewingKey"]) as? String }
                guard !stopped, let key else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string)
            } catch { textHistoryError = error.localizedDescription }
        }
    }
    func exportTextHistory() {
        guard !stopped, !textExporting, !csvExporting else { return }
        let selected = selectedInterval, keyword = textKeyword
        let interval = DateInterval(start: selected.start, end: max(selected.start, min(selected.end, Date())))
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "KeyTrail-text\(isDemo ? "-demo" : "").txt"
        panel.message = "将逐页导出全部匹配文字。成功完成前保留原目标文件；导出文件为明文。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cancellation = ExportCancellation()
        textExportCancellation = cancellation; textExporting = true; textExportNotice = "正在逐页解密并导出完整范围…"
        Task {
            defer { textExporting = false; textExportCancellation = nil }
            do {
                let count = try await rpc.perform { client in
                    let formatter = ISO8601DateFormatter()
                    var count = 0, scanned = 0, revision: Int64?, cursor: TextScanCursor?
                    try PrivateFile.write(to: url, beforePublish: { try cancellation.beginPublish() }) { append in
                        while true {
                            try cancellation.check()
                            let page = try DashboardRPC.decode(TextScanPage.self, from: client.request(textPageRequest(range: interval, keyword: keyword, cursor: cursor)))
                            if let revision, revision != page.snapshotRevision { throw RuntimeError("导出期间文字归档已变化，请重试；原目标文件已保留。") }
                            revision = page.snapshotRevision
                            for entry in page.entries {
                                let text = "\(count == 0 ? "" : "\n\n")[\(formatter.string(from: entry.metadata.timestamp))] \(entry.metadata.applicationBundleID)\n\(entry.text)"
                                try append(Data(text.utf8)); count += 1
                            }
                            scanned += page.scannedRecords
                            if !page.hasMore {
                                guard page.coverageComplete, scanned == page.totalRecords else { throw RuntimeError("文字扫描未覆盖完整范围，未生成部分导出。") }
                                break
                            }
                            guard let next = page.nextCursor, page.scannedRecords > 0 else { throw RuntimeError("文字分页未推进，未生成部分导出。") }
                            cursor = next
                        }
                        try cancellation.check()
                        _ = try client.request(["op": "textValidateSnapshot", "snapshotRevision": revision ?? 0])
                        try cancellation.check()
                    }
                    return count
                }
                if !stopped { textExportNotice = "已完整导出 \(count.formatted()) 条匹配记录：\(url.lastPathComponent)。TXT 未加密。" }
            } catch { if !stopped { textExportNotice = error.localizedDescription } }
        }
    }
    func cancelTextExport() {
        if textExportCancellation?.cancel() == false { textExportNotice = "文件已进入最终保存步骤，正在完成；此时无法取消。" }
    }

    private func refreshComparisonIfNeeded() {
        guard !comparisonInFlight, !stopped, dashboardVisible, overviewVisible, funEnabled,
              rangeMode == .today || rangeMode == .day else { return }
        let calendar = Calendar.current, now = Date()
        let selectedDay = calendar.startOfDay(for: rangeMode == .today ? now : selectedDate)
        if comparisonDay != selectedDay || comparisonTimeZone != calendar.timeZone.identifier {
            dailyComparison = nil; refreshComparison(); return
        }
        let end = calendar.dateInterval(of: .day, for: selectedDay)!.end
        guard now.timeIntervalSince(lastComparisonAttempt) >= 30,
              dailyComparison == nil || calendar.isDateInToday(selectedDay) || (end <= now && lastComparisonAttempt < end) else { return }
        refreshComparison()
    }

    private func refreshComparison() {
        guard !stopped, dashboardVisible, overviewVisible, funEnabled, rangeMode == .today || rangeMode == .day else { return }
        comparisonGeneration &+= 1
        if comparisonInFlight { comparisonPending = true; comparisonLoading = true; dailyComparison = nil; return }
        let requestGeneration = comparisonGeneration, now = Date(), calendar = Calendar.current
        let anchor = rangeMode == .today ? now : selectedDate
        comparisonDay = calendar.startOfDay(for: anchor); comparisonTimeZone = calendar.timeZone.identifier
        comparisonInFlight = true; comparisonLoading = true; comparisonError = nil; dailyComparison = nil; lastComparisonAttempt = now
        Task {
            defer {
                comparisonInFlight = false
                if requestGeneration == comparisonGeneration { comparisonLoading = false }
                if comparisonPending { comparisonPending = false; refreshComparison() }
            }
            do {
                let comparison = try await rpc.perform { client in
                    let plan = DailyComparisonPlan(anchor: anchor, now: now, calendar: calendar)
                    guard plan.start.timeIntervalSince1970 >= 0 else { throw RuntimeError("请选择 1970 年之后的日期。") }
                    let ranges = plan.querySegments.map { ["start": $0.start.timeIntervalSince1970, "end": $0.end.timeIntervalSince1970] }
                    let buckets = ranges.isEmpty ? [] : try DashboardRPC.decode([MinuteBucket].self, from: client.request(["op": "summaries", "ranges": ranges]))
                    return try DailyComparison(plan: plan, buckets: buckets)
                }
                guard requestGeneration == comparisonGeneration, dashboardVisible, overviewVisible, funEnabled, !stopped else { return }
                dailyComparison = comparison
            } catch {
                guard requestGeneration == comparisonGeneration, dashboardVisible, overviewVisible, !stopped else { return }
                comparisonError = "同时段对比读取失败：\(error.localizedDescription)"
            }
        }
    }

    func exportCSV() {
        guard !stopped, !csvExporting, !textExporting else { return }
        let interval = selectedInterval
        guard interval.duration > 0 else { errorMessage = "请选择有效的时间范围后再导出。"; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "KeyTrail-\(Date().formatted(.iso8601.year().month().day()))\(isDemo ? "-demo" : "").csv"
        panel.title = "导出完整统计 CSV"
        panel.message = "逐页导出所选范围的全部分钟统计；完整校验成功后才保存目标文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cancellation = ExportCancellation(), token = UUID()
        csvExportCancellation = cancellation; csvExportID = token
        csvExporting = true; csvExportFailed = false
        let scope = "\(interval.start.formatted(.dateTime.year().month().day().hour().minute())) 至 \(interval.end.formatted(.dateTime.year().month().day().hour().minute()))（不含终点）"
        csvExportNotice = "正在导出 \(scope) 的完整分钟统计…"
        Task {
            defer { csvExporting = false; csvExportCancellation = nil; csvExportID = nil }
            do {
                let count = try await rpc.perform { [weak self] client in
                    var lastProgress = Date.distantPast
                    return try StatisticsCSVExporter.write(to: url, start: interval.start.timeIntervalSince1970, end: interval.end.timeIntervalSince1970,
                        request: { try client.request($0) }, checkCancellation: { try cancellation.check() },
                        beginPublish: { try cancellation.beginPublish() }, progress: { written, total in
                            let now = Date()
                            guard written == total || now.timeIntervalSince(lastProgress) >= 0.2 else { return }
                            lastProgress = now
                            Task { @MainActor [weak self] in
                                guard let self, !self.stopped, self.csvExporting, self.csvExportID == token else { return }
                                self.csvExportNotice = "正在导出 \(scope)：\(written.formatted()) / \(total.formatted()) 行；完成前保留原目标文件。"
                            }
                        })
                }
                if !stopped { csvExportNotice = "已完整导出 \(count.formatted()) 行分钟统计：\(url.lastPathComponent)。范围：\(scope)。" }
            } catch {
                if !stopped { csvExportFailed = true; csvExportNotice = "CSV 导出未完成：\(error.localizedDescription)" }
            }
        }
    }

    func cancelCSVExport() {
        if csvExportCancellation?.cancel() == false { csvExportNotice = "CSV 已进入最终保存步骤，正在完成；此时无法取消。" }
    }

    func exportDailyArt() { errorMessage = "请使用每日图案卡片内的导出按钮。" }

    func deleteSelectedRange(in interval: DateInterval? = nil) {
        let target = interval ?? selectedInterval
        guard target.duration > 0 else { errorMessage = "请选择有效的时间范围后再删除。"; return }
        control(["op": "delete", "start": target.start.timeIntervalSince1970, "end": target.end.timeIntervalSince1970], failure: "删除失败")
    }

    func clearAll() { control(["op": "clear"], failure: "清空失败", pauseFirst: !isDemo) }

    func openDataFolder() { NSWorkspace.shared.selectFile(dataPath, inFileViewerRootedAtPath: "") }
    func openInputSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
    }
}
