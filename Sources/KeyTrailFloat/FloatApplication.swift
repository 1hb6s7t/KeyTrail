import AppKit
import Darwin
import KeyTrailIPC
import KeyTrailFloatingUI

private struct FloatOptions {
    let client: RuntimeClient
    let isDemo: Bool
    let collectorApp: URL?
    let dashboardApp: URL?
    let namespace: String

    init() {
        let arguments = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let configured = Bundle.main.object(forInfoDictionaryKey: "KeyTrailDataProfile") as? String ?? "KeyTrail"
        let profile = ["KeyTrail", "KeyTrail Validation", "KeyTrail Demo"].contains(configured) ? configured : "KeyTrail"
        isDemo = arguments.contains("--demo") || profile == "KeyTrail Demo"
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isDemo ? "KeyTrail Demo" : profile)
        let socket = value("--socket").map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("engine.sock")
        client = RuntimeClient(socketURL: socket)
        collectorApp = (value("--collector-app") ?? Bundle.main.object(forInfoDictionaryKey: "KeyTrailCollectorApp") as? String)
            .map { URL(fileURLWithPath: $0) }
        dashboardApp = (Bundle.main.object(forInfoDictionaryKey: "KeyTrailDashboardApp") as? String)
            .map { URL(fileURLWithPath: $0) }
        namespace = "companion." + (isDemo ? "demo" : profile) + "." + socket.deletingLastPathComponent().lastPathComponent
    }
}

@MainActor
private final class FloatDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options = FloatOptions()
    private var panel: FloatingStatsPanel?
    private var statusItem: NSStatusItem?
    private var visible = true
    private var collectorPID: pid_t?
    private var watcher: DispatchSourceProcess?
    private var connectTimer: Timer?
    private var connecting = false
    private var terminated = false
    private let connectionQueue = DispatchQueue(label: "com.auriel.keytrail.float.connect", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "键迹数据浮窗")
        item.button?.toolTip = "键迹数据浮窗 · 随时查看本机统计"
        statusItem = item
        panel = FloatingStatsPanel(client: options.client, isDemo: options.isDemo,
                                   preferencesNamespace: options.namespace,
                                   onClose: { [weak self] in self?.visible = false; self?.updateMenu() },
                                   onOpenDashboard: { [weak self] in self?.openDashboard() })
        panel?.show(); updateMenu(); connectToCollector()
        let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.connectToCollector() }
        }
        timer.tolerance = 0.5; RunLoop.main.add(timer, forMode: .common); connectTimer = timer
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel(); return false
    }

    private func connectToCollector() {
        guard !terminated, collectorPID == nil, !connecting else { return }
        connecting = true
        let client = options.client
        connectionQueue.async { [weak self] in
            let status = try? client.status()
            Task { @MainActor [weak self] in
                guard let self, !self.terminated else { return }
                self.connecting = false
                guard let status, status.isDemo == self.options.isDemo,
                      let pid = Int32(exactly: status.pid), pid > 1, kill(pid, 0) == 0 else { return }
                self.collectorPID = pid
                // Exiting the collector also exits this companion, even though it
                // was launched independently to preserve the collector signature.
                let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
                watcher.setEventHandler { NSApp.terminate(nil) }; watcher.resume(); self.watcher = watcher
                self.connectTimer?.invalidate(); self.connectTimer = nil
                self.updateMenu()
            }
        }
    }

    private func updateMenu() {
        let menu = NSMenu(); menu.delegate = self
        let heading = NSMenuItem(title: options.isDemo ? "键迹浮窗 · 演示数据" : "键迹浮窗 · 本机数据", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading); menu.addItem(.separator())
        add(menu, visible ? "隐藏数据浮窗" : "显示数据浮窗", action: #selector(togglePanel))
        add(menu, "打开完整看板", action: #selector(openDashboard))
        if collectorPID == nil, options.collectorApp != nil {
            add(menu, "打开采集程序", action: #selector(openCollector))
        }
        menu.addItem(.separator())
        add(menu, "退出浮窗（继续统计）", action: #selector(quit), key: "q")
        statusItem?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }
    private func add(_ menu: NSMenu, _ title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item)
    }
    @objc private func togglePanel() {
        if visible { panel?.close(); visible = false; updateMenu() } else { showPanel() }
    }
    private func showPanel() { visible = true; panel?.show(); updateMenu(); connectToCollector() }
    @objc private func openDashboard() {
        guard let pid = collectorPID, kill(pid, 0) == 0 else { openCollector(); return }
        if let url = options.dashboardApp, FileManager.default.fileExists(atPath: url.path) {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.auriel.keytrail.open-dashboard.\(pid)"),
            object: nil, userInfo: nil, deliverImmediately: true)
    }
    @objc private func openCollector() {
        guard let url = options.collectorApp, FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert(); alert.messageText = "采集程序尚未运行"
            alert.informativeText = "请先打开键迹。浮窗只读取本机统计，不会自行开启输入监控。"
            alert.runModal(); return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        terminated = true; connectTimer?.invalidate(); watcher?.cancel(); panel?.close()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

@main
private struct KeyTrailFloat {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared, delegate = FloatDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
