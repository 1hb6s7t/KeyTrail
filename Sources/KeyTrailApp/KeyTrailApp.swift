import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var observers: [NSObjectProtocol] = []
    private var showDashboardObserver: NSObjectProtocol?
    private var collectorExitSource: DispatchSourceProcess?
    private var watchedCollectorPID: Int32?

    func watchCollector(_ pid: Int32?) {
        guard let pid, pid > 0, pid != ProcessInfo.processInfo.processIdentifier, pid != watchedCollectorPID else { return }
        collectorExitSource?.cancel()
        watchedCollectorPID = pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        collectorExitSource = source
        source.resume()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let center = NotificationCenter.default
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateVisibility() }
            })
        }
        let showName = Notification.Name("com.auriel.keytrail.show-dashboard.\(ProcessInfo.processInfo.processIdentifier)")
        showDashboardObserver = DistributedNotificationCenter.default().addObserver(forName: showName, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.showDashboard() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidHide(_ notification: Notification) { model?.setDashboardVisible(false) }
    func applicationDidUnhide(_ notification: Notification) { updateVisibility() }
    func applicationWillTerminate(_ notification: Notification) {
        collectorExitSource?.cancel(); collectorExitSource = nil
        model?.shutdown()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let showDashboardObserver { DistributedNotificationCenter.default().removeObserver(showDashboardObserver) }
        showDashboardObserver = nil
    }

    private func showDashboard() {
        NSApp.unhide(nil)
        for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = !NSApp.isHidden && NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && $0.occlusionState.contains(.visible) && !$0.isMiniaturized && !($0 is NSPanel) }
        model?.setDashboardVisible(visible)
    }
}

@main
struct KeyTrailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("键迹 · KeyTrail", id: "dashboard") {
            DashboardView(model: model)
                .frame(minWidth: 940, minHeight: 700)
                .onAppear { delegate.model = model; model.setDashboardVisible(true) }
                .onReceive(model.$collectorPID) { delegate.watchCollector($0) }
                .onDisappear { model.setDashboardVisible(false) }
        }
        .defaultSize(width: 1440, height: 1024)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开统计看板") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut("0")
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出统计看板") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            CommandMenu("记录") {
                Button(model.isMonitoring ? "暂停记录" : "开始记录") { model.isMonitoring ? model.pause() : model.resume() }.disabled(model.isDemo)
                Button("刷新统计") { model.refresh() }.keyboardShortcut("r")
                Button("导出 CSV…") { model.exportCSV() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.csvExporting || model.textExporting)
            }
        }
    }
}
