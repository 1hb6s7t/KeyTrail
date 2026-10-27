import AppKit
import Foundation
import KeyTrailIPC

/// A read-only companion to the resident collector. It never opens the database or installs an input listener.
@MainActor
public final class FloatingStatsPanel: NSObject, NSWindowDelegate {
    private let panel: StatsWindow
    private let client: RuntimeClient
    private let isDemo: Bool
    private let namespace: String
    private let onClose: () -> Void
    private let onOpenDashboard: () -> Void
    private let reader = DispatchQueue(label: "com.auriel.keytrail.floating-stats.reader", qos: .utility)
    private let defaults = UserDefaults.standard
    private let root = StatsBackground()
    private let titleLabel = StatsLabel("键迹", size: 16, weight: .semibold)
    private let stateLabel = StatsLabel("正在连接后台…", size: 10)
    private let stateDot = NSView()
    private let compactSummary = StatsLabel("等待本地统计…", size: 12, weight: .medium)
    private let compactDetail = StatsLabel("", size: 10)
    private let periodControl = NSSegmentedControl(labels: ["今天", "当前小时"], trackingMode: .selectOne, target: nil, action: nil)
    private let footerLabel = StatsLabel("本地统计 · 每 2 秒更新", size: 9)
    private let keysCard = StatsCard(title: "键盘按键 · 次", symbol: "keyboard")
    private let clicksCard = StatsCard(title: "鼠标点击 · 次", symbol: "cursorarrow.click")
    private let distanceCard = StatsCard(title: "光标距离 · 显示点", symbol: "arrow.up.left.and.arrow.down.right")
    private let activeCard = StatsCard(title: "活跃时间", symbol: "clock")
    private var compactButton: NSButton!
    private var optionsButton: NSButton!
    private var closeButton: NSButton!
    private var dashboardButton: NSButton!
    private var timer: Timer?
    private var visible = false
    private var inFlight = false
    private var generation: UInt = 0
    private var snapshot: FloatingStatsSnapshot?
    private var lastError: String?
    private var period: FloatingStatsPeriod
    private var compact: Bool
    private var alwaysOnTop: Bool
    private var opacity: CGFloat

    public init(client: RuntimeClient, isDemo: Bool, preferencesNamespace: String,
                onClose: @escaping () -> Void, onOpenDashboard: @escaping () -> Void) {
        self.client = client
        self.isDemo = isDemo
        self.namespace = preferencesNamespace + ".floatingStats."
        self.onClose = onClose
        self.onOpenDashboard = onOpenDashboard
        let prefix = preferencesNamespace + ".floatingStats."
        period = FloatingStatsPeriod(rawValue: UserDefaults.standard.string(forKey: prefix + "period") ?? "") ?? .today
        compact = UserDefaults.standard.bool(forKey: prefix + "compact")
        alwaysOnTop = UserDefaults.standard.object(forKey: prefix + "alwaysOnTop") as? Bool ?? true
        let savedOpacity = UserDefaults.standard.double(forKey: prefix + "opacity")
        opacity = [1.0, 0.9, 0.8].contains(savedOpacity) ? CGFloat(savedOpacity) : 1
        panel = StatsWindow(contentRect: NSRect(x: 0, y: 0, width: 312, height: compact ? 112 : 270),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        configureWindow()
        configureContent()
        restorePosition()
        layoutContent()
        render()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    public func show() {
        guard !visible else { panel.orderFrontRegardless(); return }
        visible = true
        generation &+= 1
        clampToScreens()
        panel.orderFrontRegardless()
        refresh()
        let next = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        next.tolerance = 0.3
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    /// Hide and stop polling. This is also safe while a socket request is completing.
    public func close() {
        visible = false
        generation &+= 1
        timer?.invalidate()
        timer = nil
        savePosition()
        panel.orderOut(nil)
    }

    public func windowDidMove(_ notification: Notification) { savePosition() }

    private func configureWindow() {
        panel.delegate = self
        panel.title = isDemo ? "键迹 · 演示数据悬浮窗" : "键迹 · 实时统计悬浮窗"
        panel.setAccessibilityLabel(panel.title)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.alphaValue = opacity
        panel.contentView = root
        panel.appearance = NSAppearance(named: .aqua)
    }

    private func configureContent() {
        root.wantsLayer = true
        root.layer?.backgroundColor = StatsPalette.paper.cgColor
        root.layer?.cornerRadius = 18
        root.layer?.borderColor = StatsPalette.line.cgColor
        root.layer?.borderWidth = 1
        root.layer?.masksToBounds = true
        titleLabel.font = NSFont(name: "Songti SC", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.toolTip = "拖动空白区域移动悬浮窗"
        stateLabel.textColor = StatsPalette.muted
        footerLabel.textColor = StatsPalette.muted
        compactDetail.textColor = StatsPalette.muted
        compactSummary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        stateDot.wantsLayer = true
        stateDot.layer?.cornerRadius = 3
        compactButton = iconButton("rectangle.compress.vertical", label: "切换精简模式", action: #selector(toggleCompact))
        optionsButton = iconButton("ellipsis", label: "悬浮窗选项", action: #selector(showOptions))
        closeButton = iconButton("xmark", label: "隐藏悬浮窗", action: #selector(hideFromButton))
        dashboardButton = NSButton(title: "打开看板 ↗", target: self, action: #selector(openDashboard))
        dashboardButton.isBordered = false
        dashboardButton.font = .systemFont(ofSize: 10, weight: .medium)
        dashboardButton.contentTintColor = StatsPalette.indigo
        dashboardButton.setAccessibilityLabel("打开键迹看板")
        periodControl.target = self
        periodControl.action = #selector(changePeriod)
        periodControl.selectedSegment = period == .today ? 0 : 1
        periodControl.segmentStyle = .rounded
        periodControl.controlSize = .small
        periodControl.font = .systemFont(ofSize: 11, weight: .medium)
        periodControl.setWidth(138, forSegment: 0)
        periodControl.setWidth(138, forSegment: 1)
        periodControl.setAccessibilityLabel("统计时间范围")
        for view in [titleLabel, stateLabel, stateDot, compactSummary, compactDetail, periodControl,
                     footerLabel, keysCard, clicksCard, distanceCard, activeCard,
                     compactButton!, optionsButton!, closeButton!, dashboardButton!] {
            root.addSubview(view)
        }
        distanceCard.toolTip = "鼠标光标在屏幕上移动的显示点距离，不是桌面上的物理距离。"
        activeCard.toolTip = "后台统计的活跃时间；暂停、锁屏和睡眠不增加活跃时长。"
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = StatsPalette.muted
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    private func layoutContent() {
        titleLabel.frame = NSRect(x: 16, y: 11, width: 67, height: 23)
        stateDot.frame = NSRect(x: 85, y: 20, width: 6, height: 6)
        stateLabel.frame = NSRect(x: 97, y: 16, width: 111, height: 15)
        compactButton.frame = NSRect(x: 214, y: 11, width: 26, height: 25)
        optionsButton.frame = NSRect(x: 244, y: 11, width: 26, height: 25)
        closeButton.frame = NSRect(x: 274, y: 11, width: 24, height: 25)
        compactButton.image = NSImage(systemSymbolName: compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical", accessibilityDescription: compact ? "展开统计" : "精简统计")
        compactButton.toolTip = compact ? "展开统计" : "精简统计"
        compactButton.setAccessibilityLabel(compact ? "展开统计" : "精简统计")
        periodControl.frame = NSRect(x: 15, y: 45, width: 282, height: 25)
        keysCard.frame = NSRect(x: 16, y: 80, width: 135, height: 68)
        clicksCard.frame = NSRect(x: 161, y: 80, width: 135, height: 68)
        distanceCard.frame = NSRect(x: 16, y: 157, width: 135, height: 68)
        activeCard.frame = NSRect(x: 161, y: 157, width: 135, height: 68)
        compactSummary.frame = NSRect(x: 16, y: 44, width: 280, height: 19)
        compactDetail.frame = NSRect(x: 16, y: 68, width: 280, height: 16)
        footerLabel.frame = NSRect(x: 17, y: compact ? 92 : 243, width: 194, height: 15)
        dashboardButton.frame = NSRect(x: 218, y: compact ? 87 : 236, width: 79, height: 25)
        for view in [periodControl, keysCard, clicksCard, distanceCard, activeCard] { view.isHidden = compact }
        compactSummary.isHidden = !compact
        compactDetail.isHidden = !compact
    }

    private func refresh() {
        guard visible else { return }
        render() // Age the last successful value even when a slow request is still pending.
        guard !inFlight else { return }
        inFlight = true
        let requestGeneration = generation
        let requestedPeriod = period
        let runtimeClient = client
        let expectedDemo = isDemo
        reader.async { [weak self] in
            let result = Result {
                let value = try FloatingStatsSnapshot.load(client: runtimeClient, period: requestedPeriod)
                guard value.collector.isDemo == expectedDemo else {
                    throw RuntimeError("后台数据模式与当前窗口不一致，已拒绝显示混合数据。")
                }
                return value
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard self.visible else { return }
                guard requestGeneration == self.generation, requestedPeriod == self.period else {
                    self.refresh()
                    return
                }
                switch result {
                case .success(let value): self.snapshot = value; self.lastError = nil
                case .failure(let error): self.lastError = error.localizedDescription
                }
                self.render()
            }
        }
    }

    private func render() {
        let demo = isDemo || snapshot?.collector.isDemo == true
        let boundaryChanged = snapshot.map { value in
            (try? FloatingStatsRange(period: period).start) != value.range.start
        } ?? false
        let stale = lastError != nil || snapshot?.isStale(at: Date()) == true || boundaryChanged
        if let value = snapshot {
            keysCard.value = FloatingStatsFormat.count(value.keyPresses)
            clicksCard.value = FloatingStatsFormat.count(value.totalClicks)
            distanceCard.value = FloatingStatsFormat.distance(value.mouseDistancePoints)
            activeCard.value = FloatingStatsFormat.activity(value.totalActiveSeconds)
            compactSummary.stringValue = "\(period.title)  键盘 \(FloatingStatsFormat.count(value.keyPresses)) · 点击 \(FloatingStatsFormat.count(value.totalClicks))"
            compactDetail.stringValue = "光标 \(FloatingStatsFormat.distance(value.mouseDistancePoints))  ·  活跃 \(FloatingStatsFormat.activity(value.totalActiveSeconds))"
            if stale {
                stateLabel.stringValue = boundaryChanged ? "时段已切换 · 更新中" : lastError == nil ? "更新延迟 · 数据已过期" : "未连接 · 数据已过期"
                stateDot.layer?.backgroundColor = StatsPalette.warning.cgColor
                footerLabel.stringValue = boundaryChanged ? "上一时段数据 · 等待更新" : demo ? "演示数据 · 保留上次结果" : "已过期 · 保留上次结果"
            } else {
                stateLabel.stringValue = demo ? "演示数据" : value.collector.paused ? "已暂停" : !value.collector.permissionGranted ? "等待授权" : value.collector.suspended ? "暂缓记录" : value.collector.isRecording ? "记录中" : "采集已停止"
                stateDot.layer?.backgroundColor = (demo ? StatsPalette.lavender : value.collector.isRecording ? StatsPalette.indigo : StatsPalette.warning).cgColor
                footerLabel.stringValue = demo ? "演示数据 · 非真实输入" : "本地统计 · 每 2 秒更新"
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let updated = "上次成功更新：\(formatter.string(from: value.capturedAt))"
            footerLabel.toolTip = updated
            stateLabel.toolTip = [value.collector.statusText, updated, lastError].compactMap { $0 }.joined(separator: "\n")
        } else {
            for card in [keysCard, clicksCard, distanceCard, activeCard] { card.value = "—" }
            stateLabel.stringValue = lastError == nil ? "正在连接后台…" : "后台未连接"
            stateDot.layer?.backgroundColor = StatsPalette.warning.cgColor
            compactSummary.stringValue = "\(period.title) · 等待本地统计"
            compactDetail.stringValue = lastError == nil ? "正在读取后台数据…" : "后台连接恢复后自动更新"
            footerLabel.stringValue = demo ? "演示模式 · 等待演示后台" : lastError == nil ? "本地统计 · 每 2 秒更新" : "连接恢复后自动更新"
            stateLabel.toolTip = lastError
            footerLabel.toolTip = lastError
        }
        titleLabel.stringValue = demo ? "键迹 · 演示" : "键迹"
        titleLabel.font = NSFont(name: "Songti SC", size: demo ? 12 : 17) ?? .systemFont(ofSize: 14)
        for card in [keysCard, clicksCard, distanceCard, activeCard] { card.alphaValue = stale ? 0.64 : 1 }
    }

    @objc private func changePeriod() {
        setPeriod(periodControl.selectedSegment == 0 ? .today : .currentHour)
    }

    private func setPeriod(_ selection: FloatingStatsPeriod) {
        guard period != selection else { return }
        period = selection
        defaults.set(period.rawValue, forKey: namespace + "period")
        periodControl.selectedSegment = period == .today ? 0 : 1
        generation &+= 1
        snapshot = nil
        lastError = nil
        render()
        refresh()
    }

    @objc private func toggleCompact() {
        compact.toggle()
        defaults.set(compact, forKey: namespace + "compact")
        let previous = panel.frame
        let height: CGFloat = compact ? 112 : 270
        panel.setFrame(NSRect(x: previous.minX, y: previous.maxY - height, width: 312, height: height), display: true)
        layoutContent()
        clampToScreens()
        savePosition()
    }

    @objc private func showOptions() {
        let menu = NSMenu(title: "悬浮窗选项")
        let top = NSMenuItem(title: "始终置顶", action: #selector(toggleAlwaysOnTop), keyEquivalent: "")
        top.state = alwaysOnTop ? .on : .off
        top.target = self
        menu.addItem(top)
        menu.addItem(.separator())
        for (index, title) in ["不透明 · 100%", "轻透明 · 90%", "透明 · 80%"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.state = abs(opacity - [1.0, 0.9, 0.8][index]) < 0.01 ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (index, title) in ["统计今天", "统计当前小时"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(selectPeriodFromMenu(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            item.state = (index == 0) == (period == .today) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: optionsButton.bounds.maxY + 3), in: optionsButton)
    }

    @objc private func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        defaults.set(alwaysOnTop, forKey: namespace + "alwaysOnTop")
        panel.level = alwaysOnTop ? .floating : .normal
    }
    @objc private func setOpacity(_ sender: NSMenuItem) {
        opacity = [1.0, 0.9, 0.8][sender.tag]
        defaults.set(Double(opacity), forKey: namespace + "opacity")
        panel.alphaValue = opacity
    }
    @objc private func selectPeriodFromMenu(_ sender: NSMenuItem) { setPeriod(sender.tag == 0 ? .today : .currentHour) }
    @objc private func openDashboard() { onOpenDashboard() }
    @objc private func hideFromButton() { close(); onClose() }
    @objc private func screensChanged() { clampToScreens(); savePosition() }

    private func restorePosition() {
        if let saved = defaults.string(forKey: namespace + "frame") {
            let frame = NSRectFromString(saved)
            if frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width > 0, frame.height > 0 {
                panel.setFrameOrigin(frame.origin)
                clampToScreens()
                return
            }
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 332, y: screen.visibleFrame.maxY - 28))
        }
        clampToScreens()
    }

    private func savePosition() { defaults.set(NSStringFromRect(panel.frame), forKey: namespace + "frame") }

    private func clampToScreens() {
        let frame = panel.frame
        let screen = NSScreen.screens.max { first, second in
            let a = first.visibleFrame.intersection(frame)
            let b = second.visibleFrame.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
        guard let candidate = screen else { return }
        let intersects = !candidate.visibleFrame.intersection(frame).isNull
        let bounds = (intersects ? candidate : NSScreen.main ?? candidate).visibleFrame
        let x = min(max(frame.minX, bounds.minX), max(bounds.minX, bounds.maxX - frame.width))
        let y = min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
private final class StatsWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class StatsBackground: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

@MainActor
private final class StatsLabel: NSTextField {
    init(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: size, weight: weight)
        textColor = StatsPalette.ink
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.usesSingleLineMode = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

@MainActor
private final class StatsCard: NSView {
    private let label: StatsLabel
    private let number = StatsLabel("—", size: 20, weight: .semibold)
    private let icon = NSImageView()
    var value: String {
        get { number.stringValue }
        set {
            number.stringValue = newValue
            number.setAccessibilityLabel(label.stringValue + "：" + newValue)
            number.toolTip = label.stringValue + "：" + newValue
            needsLayout = true
        }
    }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    init(title: String, symbol: String) {
        label = StatsLabel(title, size: 9)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = StatsPalette.surface.cgColor
        layer?.cornerRadius = 11
        layer?.borderWidth = 0.5
        layer?.borderColor = StatsPalette.line.cgColor
        label.textColor = StatsPalette.muted
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = StatsPalette.indigo
        number.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        number.cell?.lineBreakMode = .byTruncatingTail
        addSubview(label); addSubview(number); addSubview(icon)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: 11, width: 13, height: 13)
        label.frame = NSRect(x: 27, y: 10, width: bounds.width - 33, height: 15)
        number.frame = NSRect(x: 10, y: 31, width: bounds.width - 18, height: 26)
        var size: CGFloat = 20
        while size > 12 {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            if (value as NSString).size(withAttributes: [.font: font]).width <= number.bounds.width - 4 { break }
            size -= 1
        }
        number.font = .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private enum StatsPalette {
    static let paper = NSColor(calibratedRed: 0.980, green: 0.980, blue: 0.969, alpha: 1)
    static let surface = NSColor(calibratedRed: 0.992, green: 0.992, blue: 0.996, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.13, green: 0.20, blue: 0.32, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.42, green: 0.45, blue: 0.56, alpha: 1)
    static let indigo = NSColor(calibratedRed: 0.34, green: 0.43, blue: 0.78, alpha: 1)
    static let lavender = NSColor(calibratedRed: 0.69, green: 0.67, blue: 0.88, alpha: 1)
    static let line = NSColor(calibratedRed: 0.85, green: 0.86, blue: 0.93, alpha: 1)
    static let warning = NSColor(calibratedRed: 0.67, green: 0.47, blue: 0.24, alpha: 1)
}
