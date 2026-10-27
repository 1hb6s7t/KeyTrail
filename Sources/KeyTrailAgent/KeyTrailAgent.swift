import AppKit
import Foundation
import KeyTrailIPC
import KeyTrailRuntime

@MainActor
final class AgentDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var runtime: RuntimeController?
    private var item: NSStatusItem?
    private var dashboard: Process?
    private var pet: Process?
    private var petStopping = false
    private var isTerminating = false
    private var petOpenObserver: NSObjectProtocol?
    private var floatingPanel: ResidentFloatingStatsPanel?
    private var signalSource: DispatchSourceSignal?
    private let isDemo = CommandLine.arguments.contains("--demo") || Bundle.main.bundleIdentifier == "com.auriel.keytrail.preview"
    private let headless = CommandLine.arguments.contains("--headless")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            var directory: URL?
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
                directory = URL(fileURLWithPath: path, isDirectory: true)
            }
            let runtime = try RuntimeController(isDemo: isDemo, directory: directory)
            self.runtime = runtime
            runtime.petAvailable = [petBundle.appendingPathComponent("Contents/MacOS/KeyTrailPet"),
                petBundle.appendingPathComponent("Contents/Resources/libLive2DCubismCore.dylib"),
                petBundle.appendingPathComponent("Contents/Resources/standard/cat.model3.json")]
                .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            runtime.onStatusChange = { [weak self] _ in self?.updateMenu() }
            runtime.onShutdown = { NSApp.terminate(nil) }
            runtime.onPreferencesChange = { [weak self] in
                self?.updateFloatingPanel(); self?.updatePet(); self?.updateMenu()
            }
            try runtime.startServer()
            if !headless {
                item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item?.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "键迹 Rust 后台")
                item?.button?.toolTip = "键迹 · Rust 轻量后台"
                updateMenu()
                updateFloatingPanel()
                petOpenObserver = DistributedNotificationCenter.default().addObserver(
                    forName: Notification.Name("com.auriel.keytrail.open-dashboard.\(ProcessInfo.processInfo.processIdentifier)"),
                    object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor in self?.openDashboard() }
                    }
                updatePet()
                if runtime.preferences.launchAtLoginEnabled && !isDemo { try? runtime.start(requestPermission: false) }
                if !CommandLine.arguments.contains("--background") && !runtime.preferences.launchAtLoginEnabled { openDashboard() }
            }
            signal(SIGTERM, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }; source.resume(); signalSource = source
        } catch {
            if !headless {
                let alert = NSAlert(); alert.messageText = "键迹后台启动失败"; alert.informativeText = error.localizedDescription; alert.runModal()
            } else { fputs("\(error.localizedDescription)\n", stderr) }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openDashboard(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do { try runtime?.pause(); return .terminateNow }
        catch {
            if headless { fputs("保存失败，暂不退出：\(error.localizedDescription)\n", stderr) }
            else {
                let alert = NSAlert(); alert.messageText = "统计尚未保存，暂不退出"
                alert.informativeText = "采集已暂停，待保存数据仍在内存中。请检查磁盘后再次退出。\n\(error.localizedDescription)"
                alert.runModal()
            }
            return .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        if let dashboard, dashboard.isRunning { dashboard.terminate() }
        if let pet, pet.isRunning { pet.terminate() }
        if let petOpenObserver { DistributedNotificationCenter.default().removeObserver(petOpenObserver) }
        floatingPanel?.close(); floatingPanel = nil
        runtime?.shutdown()
        signalSource?.cancel()
    }

    private var petBundle: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyTrailPet.app")
    }

    private func updatePet() {
        guard !headless, !isTerminating, let runtime else { return }
        guard runtime.preferences.petEnabled, runtime.petAvailable else {
            if let pet, pet.isRunning { petStopping = true; pet.terminate() }
            // Keep the reference until exit so a rapid off/on cannot create two pets.
            return
        }
        if pet != nil { return }
        petStopping = false
        let process = Process()
        process.executableURL = petBundle.appendingPathComponent("Contents/MacOS/KeyTrailPet")
        process.arguments = ["--collector-pid", String(ProcessInfo.processInfo.processIdentifier),
                             "--socket", runtime.directory.appendingPathComponent("engine.sock").path,
                             "--journal-app", Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyTrailDashboard.app").path]
        if isDemo { process.arguments?.append("--demo") }
        process.terminationHandler = { [weak self] terminated in Task { @MainActor in
            guard let self, self.pet?.processIdentifier == terminated.processIdentifier else { return }
            self.pet = nil
            let wasStopping = self.petStopping; self.petStopping = false
            if wasStopping { self.updatePet() }
            // A deliberately hidden pet stays hidden; unexpected exits do not loop.
            self.updateMenu()
        } }
        do { try process.run(); pet = process }
        catch {
            let alert = NSAlert(); alert.messageText = "桌面小猫暂时无法打开"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    private func updateFloatingPanel() {
        guard !headless, let runtime else { return }
        if runtime.preferences.floatingWindowEnabled {
            if floatingPanel == nil {
                floatingPanel = ResidentFloatingStatsPanel(runtime: runtime, didClose: { [weak self] in
                    guard let self, let runtime = self.runtime else { return }
                    self.floatingPanel = nil
                    var preferences = runtime.preferences; preferences.floatingWindowEnabled = false
                    if let data = try? JSONEncoder().encode(preferences), let object = try? JSONSerialization.jsonObject(with: data) {
                        _ = runtime.handle(["op": "setPreferences", "preferences": object])
                    }
                }, openDashboard: { [weak self] in self?.openDashboard() })
            }
            floatingPanel?.show()
        } else {
            let previous = floatingPanel; floatingPanel = nil; previous?.close()
        }
    }

    private func updateMenu() {
        guard let runtime else { return }
        let status = runtime.status
        let menu = NSMenu(); menu.delegate = self
        let label = NSMenuItem(title: status.statusText, action: nil, keyEquivalent: "")
        label.isEnabled = false; menu.addItem(label)
        menu.addItem(.separator())
        add(menu, "打开统计看板", action: #selector(openDashboard), key: "0")
        add(menu, runtime.preferences.floatingWindowEnabled ? "隐藏数据浮窗" : "显示数据浮窗", action: #selector(toggleFloatingPanel))
        if runtime.petAvailable {
            add(menu, runtime.preferences.petEnabled ? "隐藏桌面小猫" : "显示桌面小猫", action: #selector(togglePet))
        }
        if !isDemo {
            add(menu, status.monitoring ? "暂停记录" : "授权并开始记录", action: #selector(toggleMonitoring))
            if status.monitoring {
                add(menu, "暂停 15 分钟", action: #selector(pause15))
                add(menu, "暂停 1 小时", action: #selector(pause60))
            }
        }
        let info = NSMenuItem(title: "Rust 核心 · 关闭看板可释放界面内存", action: nil, keyEquivalent: "")
        info.isEnabled = false; menu.addItem(info)
        menu.addItem(.separator()); add(menu, "退出键迹（停止全部进程）", action: #selector(quit), key: "q")
        item?.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) { updateMenu() }
    private func add(_ menu: NSMenu, _ title: String, action: Selector, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.target = self; menu.addItem(entry)
    }
    @objc private func toggleMonitoring() {
        guard let runtime else { return }
        do { if runtime.status.monitoring { try runtime.pause() } else { try runtime.start(requestPermission: true) } }
        catch { let alert = NSAlert(); alert.messageText = "暂时无法开始记录"; alert.informativeText = error.localizedDescription; alert.runModal() }
        updateMenu()
    }
    @objc private func pause15() { pauseFor(15) }
    @objc private func pause60() { pauseFor(60) }
    private func pauseFor(_ minutes: Int) {
        do { try runtime?.pause(minutes: minutes) }
        catch { let alert = NSAlert(); alert.messageText = "已停止采集，保存需要重试"; alert.informativeText = error.localizedDescription; alert.runModal() }
        updateMenu()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleFloatingPanel() {
        guard let runtime else { return }
        var preferences = runtime.preferences; preferences.floatingWindowEnabled.toggle()
        if let data = try? JSONEncoder().encode(preferences),
           let object = try? JSONSerialization.jsonObject(with: data) {
            let response = runtime.handle(["op": "setPreferences", "preferences": object])
            if response["ok"] as? Bool != true {
                let alert = NSAlert(); alert.messageText = "浮窗设置未能保存"
                alert.informativeText = response["error"] as? String ?? "请稍后重试。"; alert.runModal()
            }
        }
    }
    @objc private func togglePet() {
        guard let runtime else { return }
        var preferences = runtime.preferences; preferences.petEnabled.toggle()
        if let data = try? JSONEncoder().encode(preferences),
           let object = try? JSONSerialization.jsonObject(with: data) {
            let response = runtime.handle(["op": "setPreferences", "preferences": object])
            if response["ok"] as? Bool != true {
                let alert = NSAlert(); alert.messageText = "小猫设置未能保存"
                alert.informativeText = response["error"] as? String ?? "请稍后重试。"; alert.runModal()
            }
        }
    }
    @objc private func openDashboard() {
        guard !headless, !isTerminating else { return }
        if let dashboard, dashboard.isRunning {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.auriel.keytrail.show-dashboard.\(dashboard.processIdentifier)"),
                object: nil, userInfo: nil, deliverImmediately: true
            )
            NSRunningApplication(processIdentifier: dashboard.processIdentifier)?.activate(options: [.activateAllWindows])
            return
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyTrailDashboard.app/Contents/MacOS/KeyTrailDashboard")
        let development = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("KeyTrailDashboard")
        let executable = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : development
        let process = Process(); process.executableURL = executable; process.arguments = isDemo ? ["--demo"] : []
        if isDemo, CommandLine.arguments.contains(where: { $0.hasPrefix("--test-directory") }), let runtime {
            // A positional path suppresses SwiftUI's automatic untitled window.
            // Keep the isolated path inside its option when launching the helper.
            process.arguments?.append("--test-directory=" + runtime.directory.path)
        }
        process.terminationHandler = { [weak self] terminated in Task { @MainActor in
            if self?.dashboard?.processIdentifier == terminated.processIdentifier { self?.dashboard = nil }
        } }
        do { try process.run(); dashboard = process }
        catch { let alert = NSAlert(); alert.messageText = "看板无法打开"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }
}

@main
struct KeyTrailAgent {
    @MainActor static func main() {
        // A disconnected client or framework pipe must report EPIPE, not kill
        // the resident agent. Install before AppKit/runtime/Keychain work starts.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AgentDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
