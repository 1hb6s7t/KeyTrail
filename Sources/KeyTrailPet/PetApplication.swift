import AppKit
import QuartzCore
import KeyTrailIPC
import Darwin

private struct PetOptions {
    let isDemo: Bool
    let collectorPID: pid_t?
    let client: RuntimeClient
    let modelPath: String?
    let corePath: String?
    let checkModel: Bool
    let checkOutput: String?
    init() {
        let args = CommandLine.arguments
        func value(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        collectorPID = value("--collector-pid").flatMap(Int32.init)
        isDemo = args.contains("--demo")
        let socket = value("--socket").map { URL(fileURLWithPath: $0) } ?? RuntimePaths.socketURL(isDemo: isDemo)
        client = RuntimeClient(socketURL: socket)
        modelPath = value("--model") ?? Bundle.main.resourceURL?.appendingPathComponent("standard/cat.model3.json").path
        let bundledCore = Bundle.main.resourceURL?.appendingPathComponent("libLive2DCubismCore.dylib")
        corePath = value("--core-library") ?? bundledCore.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
        checkOutput = value("--render-check")
        checkModel = args.contains("--check-model") || checkOutput != nil
    }
}

private final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CatView: NSView {
    var openDashboard: (() -> Void)?
    var showMenu: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { openDashboard?() }
        else { window?.performDrag(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) { showMenu?(event) }
}

private final class PetApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: PetOptions
    private var panel: PetPanel?
    private var setup: NSWindow?
    private var setupMessage: NSTextField?
    private var renderer: CatMetalRenderer?
    private var frameTimer: Timer?
    private var pollTimer: DispatchSourceTimer?
    private var processWatch: DispatchSourceProcess?
    private var snapshot = PetSnapshot.idle
    private var lastUpdate = Date.distantPast
    private var lastFrame = Date.distantPast
    private var lastActivity = Date.distantPast
    private var lastRenderedSnapshot: PetSnapshot?
    private var lastRenderedSize = CGSize.zero
    private var lastKeyboardPresentationRevision: UInt64 = 0
    private var modelPath: String?
    private var corePath: String?
    private var statusItem: NSStatusItem?
    private let pollQueue = DispatchQueue(label: "com.auriel.keytrail.pet.snapshot", qos: .utility)
    init(options: PetOptions) {
        self.options = options; modelPath = options.modelPath; corePath = options.corePath
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let pid = options.collectorPID, pid > 1, kill(pid, 0) == 0 else {
            showSetup("请从 KeyTrail 菜单打开桌面猫。后台未运行，本窗口不会采集输入。")
            return
        }
        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watcher.setEventHandler { NSApp.terminate(nil) }; watcher.resume(); processWatch = watcher
        // The setup status item remains reachable even if the model cannot load.
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "键迹猫"; status.menu = menu(); statusItem = status
        loadModel()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                let value = try self.options.client.request(["op": "petState"])
                let state = try JSONDecoder().decode(PetSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
                DispatchQueue.main.async { [weak self] in self?.received(state) }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.snapshot = .idle
                    self?.panel?.title = "KeyTrail 桌面猫 · 后台连接中断"
                    self?.statusItem?.button?.title = "键迹猫 · 未连接"
                }
            }
        }
        timer.resume(); pollTimer = timer
        // Keep release/reset frames flowing while AppKit tracks menus or drags.
        let frames = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.frame() }
        RunLoop.main.add(frames, forMode: .common)
        frameTimer = frames
    }
    private func received(_ state: PetSnapshot) {
        if !state.enabled { NSApp.terminate(nil); return }
        if state.revision != snapshot.revision { lastActivity = Date() }
        let menuChanged = snapshot.suspended != state.suspended
        snapshot = state; lastUpdate = Date()
        renderer?.prepareKeyboard(state)
        if menuChanged { statusItem?.menu = menu() }
        let title = state.suspended ? "KeyTrail 桌面猫 · 采集已暂停" : "KeyTrail 桌面猫"
        if panel?.title != title { panel?.title = title }
        updateKeyboardStatus()
    }
    private func updateKeyboardStatus() {
        let issue = renderer?.keyboardStatus(snapshot)
        let statusTitle = issue != nil ? (snapshot.keyboardKeys == nil ? "键迹猫 · 需更新后台" : "键迹猫 · 键位不可用") : (snapshot.suspended ? "键迹猫 · 已暂停" : "键迹猫")
        if statusItem?.button?.title != statusTitle { statusItem?.button?.title = statusTitle }
        if statusItem?.button?.toolTip != issue { statusItem?.button?.toolTip = issue }
    }
    private func frame() {
        guard let renderer, panel?.isVisible == true else { return }
        do { try renderer.checkFailure() }
        catch { self.renderer = nil; panel?.orderOut(nil); showSetup(error.localizedDescription); return }
        let now = Date()
        // Never leave a paw held when the collector becomes unreachable.
        if now.timeIntervalSince(lastUpdate) > 0.5 { snapshot = .idle }
        renderer.prepareKeyboard(snapshot)
        updateKeyboardStatus()
        let active = !snapshot.suspended && (now.timeIntervalSince(lastActivity) < 1 || snapshot.leftPawHeld || snapshot.rightPawHeld || !(snapshot.keyboardKeys ?? []).isEmpty)
        let keyboardRevision = renderer.keyboardPresentationRevision
        let poseChanged = snapshot != lastRenderedSnapshot || keyboardRevision != lastKeyboardPresentationRevision
        // Reset or newly prepared keys must not wait for the idle throttle.
        // The shared frame timer still caps all presentation at 30 Hz.
        guard poseChanged || now.timeIntervalSince(lastFrame) >= (active ? 1.0 / 30.0 - 0.005 : 0.5) else { return }
        lastFrame = now
        let size = NSSize(width: (panel?.frame.width ?? 0) * (panel?.backingScaleFactor ?? 1),
                          height: (panel?.frame.height ?? 0) * (panel?.backingScaleFactor ?? 1))
        // A fixed pose has no idle animation. Retain the last drawable instead
        // of repeatedly evaluating Core, allocating buffers and submitting GPU work.
        guard snapshot != lastRenderedSnapshot || size != lastRenderedSize || keyboardRevision != lastKeyboardPresentationRevision else { return }
        if let panel {
            renderer.layer.contentsScale = panel.backingScaleFactor
            renderer.layer.drawableSize = NSSize(width: panel.frame.width * panel.backingScaleFactor, height: panel.frame.height * panel.backingScaleFactor)
        }
        do {
            if try renderer.draw(snapshot) {
                lastRenderedSnapshot = snapshot; lastRenderedSize = size
                // Capture the revision from before drawing. If a worker finishes
                // during this frame, the next frame must still present its result.
                lastKeyboardPresentationRevision = keyboardRevision
            }
        }
        catch { self.renderer = nil; panel?.orderOut(nil); showSetup(error.localizedDescription) }
    }
    private func loadModel() {
        lastRenderedSnapshot = nil; lastRenderedSize = .zero
        do {
            guard let modelPath, FileManager.default.fileExists(atPath: modelPath) else { throw PetFailure("标准猫模型资源缺失。请重新安装包含标准 BongoCat 资源的 KeyTrail 开发构建。") }
            let model = try CubismModel(manifest: URL(fileURLWithPath: modelPath), library: corePath)
            let metal = CAMetalLayer()
            let renderer = try CatMetalRenderer(model: model, layer: metal)
            let width: CGFloat = 290
            let ratio = CGFloat(model.canvasSize.y / model.canvasSize.x)
            let height = min(420, max(150, width * ratio))
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let rect = NSRect(x: screen.maxX - width - 28, y: screen.minY + 30, width: width, height: height)
            panel?.close()
            let panel = PetPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.delegate = self
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .floating; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true; panel.animationBehavior = .none
            panel.setFrameAutosaveName("KeyTrailPetPanel")
            // Recover windows saved on a display which is no longer connected.
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) { panel.setFrame(rect, display: false) }
            let view = CatView(frame: NSRect(origin: .zero, size: panel.frame.size))
            view.wantsLayer = true; view.layer = metal
            view.openDashboard = { [weak self] in self?.openDashboard() }
            view.showMenu = { [weak self, weak view] event in
                guard let self, let view else { return }
                NSMenu.popUpContextMenu(self.menu(), with: event, for: view)
            }
            panel.contentView = view
            self.panel = panel; self.renderer = renderer
            setup?.orderOut(nil)
            panel.orderFrontRegardless()
            lastFrame = .distantPast; frame()
        } catch { renderer = nil; panel?.orderOut(nil); showSetup(error.localizedDescription) }
    }
    private func showSetup(_ message: String) {
        if let setup { setupMessage?.stringValue = message; setup.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "KeyTrail 桌面猫设置"; window.isReleasedWhenClosed = false; window.delegate = self
        let title = NSTextField(labelWithString: "连接 BongoCat 动画")
        title.font = .boldSystemFont(ofSize: 19); title.frame = NSRect(x: 24, y: 210, width: 460, height: 28)
        let label = NSTextField(wrappingLabelWithString: message)
        label.frame = NSRect(x: 24, y: 95, width: 460, height: 104)
        let retryButton = NSButton(title: "重新载入", target: self, action: #selector(retryModel))
        retryButton.frame = NSRect(x: 24, y: 44, width: 146, height: 34)
        let quitButton = NSButton(title: "关闭桌面猫", target: self, action: #selector(hidePet))
        quitButton.frame = NSRect(x: 348, y: 44, width: 138, height: 34)
        let note = NSTextField(labelWithString: "模型与动画组件均在本机运行；不新增输入监听，不上传任何数据。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.frame = NSRect(x: 24, y: 15, width: 460, height: 18)
        [title, label, retryButton, quitButton, note].forEach { window.contentView?.addSubview($0) }
        setup = window; setupMessage = label; window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func retryModel() { loadModel() }
    private func menu() -> NSMenu {
        let menu = NSMenu()
        if let issue = renderer?.keyboardStatus(snapshot) {
            let item = NSMenuItem(title: issue, action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item); menu.addItem(.separator())
        }
        func add(_ title: String, _ selector: Selector) { let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        add("打开 KeyTrail 看板", #selector(openDashboard))
        if options.isDemo {
            let info = NSMenuItem(title: "预览模式 · 不监听输入", action: nil, keyEquivalent: "")
            info.isEnabled = false; menu.addItem(info)
        } else {
            add(snapshot.suspended ? "继续统计" : "暂停统计", #selector(togglePause))
        }
        menu.addItem(.separator())
        add("重置小猫姿态", #selector(resetPetPose))
        add("关闭桌面猫", #selector(hidePet))
        return menu
    }
    @objc private func resetPetPose() {
        pollQueue.async { [weak self] in
            guard let self else { return }
            do {
                let value = try self.options.client.request(["op": "resetPetPose"])
                let state = try JSONDecoder().decode(PetSnapshot.self, from: JSONSerialization.data(withJSONObject: value))
                DispatchQueue.main.async { [weak self] in self?.received(state) }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.showSetup("姿态重置失败：\(error.localizedDescription)") }
            }
        }
    }
    @objc private func openDashboard() {
        guard let pid = options.collectorPID else { return }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.auriel.keytrail.open-dashboard.\(pid)"), object: nil, userInfo: nil, deliverImmediately: true)
    }
    @objc private func togglePause() {
        let operation = snapshot.suspended ? "resume" : "pause"
        pollQueue.async { [weak self] in
            guard let self else { return }
            do { _ = try self.options.client.request(["op": operation, "requestPermission": false]) }
            catch { DispatchQueue.main.async { self.showSetup(error.localizedDescription) } }
        }
    }
    @objc private func hidePet() {
        guard let pid = options.collectorPID, pid > 1, kill(pid, 0) == 0 else { NSApp.terminate(nil); return }
        pollQueue.async { [weak self] in
            guard let self else { return }
            do {
                guard let details = try self.options.client.request(["op": "preferences"]) as? [String: Any], var preferences = details["preferences"] as? [String: Any] else { throw PetFailure("后台偏好设置格式不正确。") }
                preferences["petEnabled"] = false
                _ = try self.options.client.request(["op": "setPreferences", "preferences": preferences])
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } catch { DispatchQueue.main.async { self.showSetup(error.localizedDescription) } }
        }
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === setup, renderer == nil { hidePet() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        frameTimer?.invalidate(); pollTimer?.cancel(); processWatch?.cancel()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

@main
struct KeyTrailPetMain {
    static func main() {
        let options = PetOptions()
        if options.checkModel {
            do {
                guard let path = options.modelPath else { throw PetFailure("--check-model 需要 --model 路径。") }
                let model = try CubismModel(manifest: URL(fileURLWithPath: path), library: options.corePath)
                model.apply(.idle); let idle = try model.meshes()
                let pressed = PetState(enabled: true, suspended: false, leftPawHeld: true, rightPawHeld: true, mouseButtonsMask: 3, gazeX: 0.5, gazeY: -0.5, keyboardKeys: [.keyA])
                model.apply(pressed); let active = try model.meshes()
                func changedDrawables(_ meshes: [CatMesh]) -> Int {
                    zip(idle, meshes).filter { a, b in
                        zip(a.vertices, b.vertices).contains { $0.position != $1.position } || a.opacity != b.opacity || a.visible != b.visible
                    }.count
                }
                func changes(for state: PetState) throws -> Int {
                    model.apply(state); return changedDrawables(try model.meshes())
                }
                let changed = changedDrawables(active)
                let leftChanged = try changes(for: PetState(enabled: true, leftPawHeld: true, keyboardKeys: [.keyA]))
                let rightChanged = try changes(for: PetState(enabled: true, rightPawHeld: true, mouseButtonsMask: 1))
                // Zero pulse is intentional: middle-button holds must not snap
                // back to rest after the short press animation expires.
                let middleHeldChanged = try changes(for: PetState(enabled: true, rightPawHeld: true, rightPulseRemainingMs: 0, mouseButtonsMask: 4))
                var suspended = pressed; suspended.suspended = true
                let suspendedReset = try changes(for: suspended) == 0
                var disabled = pressed; disabled.enabled = false
                let disabledReset = try changes(for: disabled) == 0
                let releasedReset = try changes(for: PetState(enabled: true)) == 0
                let legacy = PetState(enabled: true, leftPawHeld: true, leftPulseRemainingMs: 140, keyboardKeys: nil)
                let legacyKeepsRaisedPaw = try changes(for: legacy) == 0
                let emptyKeysKeepRaisedPaw = try changes(for: PetState(enabled: true, leftPawHeld: true, leftPulseRemainingMs: 140, keyboardKeys: [])) == 0
                let waitingState = PetState(enabled: true, leftPawHeld: true, keyboardKeys: [.keyA])
                model.apply(waitingState, keyboardOverlayReady: false)
                let pendingOverlayKeepsRaisedPaw = changedDrawables(try model.meshes()) == 0
                let keyAssetsComplete = model.keyboardOverlayURLs.count == PetKeyboardKey.allCases.count
                var poseChecksPassed = changed > 0 && leftChanged > 0 && rightChanged > 0 && middleHeldChanged > 0 && suspendedReset && disabledReset && releasedReset && legacyKeepsRaisedPaw && emptyKeysKeepRaisedPaw && pendingOverlayKeepsRaisedPaw && keyAssetsComplete
                var overlayEvidence: [String: Any] = ["rendered": false]
                let renderer = try CatMetalRenderer(model: model, layer: CAMetalLayer())
                if let output = options.checkOutput {
                    let url = URL(fileURLWithPath: output)
                    try renderer.renderPNG(.idle, to: url)
                    func outputURL(_ suffix: String) -> URL { url.deletingPathExtension().appendingPathExtension("\(suffix).png") }
                    try renderer.renderPNG(pressed, to: outputURL("active"))
                    var distinctImages: [Data] = []
                    for key in [PetKeyboardKey.keyA, .keyB, .space] {
                        let target = outputURL(key.rawValue)
                        try renderer.renderPNG(PetState(enabled: true, leftPawHeld: true, keyboardKeys: [key]), to: target)
                        distinctImages.append(try Data(contentsOf: target))
                    }
                    let combo = PetState(enabled: true, leftPawHeld: true, keyboardKeys: [.controlLeft, .shiftLeft, .keyA])
                    try renderer.renderPNG(combo, to: outputURL("ControlShiftA"))
                    // Exercise more simultaneous keys than the image cache limit;
                    // every key is composed, rather than truncating to 12 keys.
                    try renderer.renderPNG(PetState(enabled: true, keyboardKeys: Array(PetKeyboardKey.allCases.prefix(14))), to: outputURL("cache-pressure"))
                    try renderer.renderPNG(PetState(enabled: true), to: outputURL("released"))
                    try renderer.renderPNG(suspended, to: outputURL("suspended"))
                    try renderer.renderPNG(legacy, to: outputURL("legacy"))
                    let idlePNG = try Data(contentsOf: url)
                    let distinct = Set(distinctImages).count == 3
                    let releasedPixelsReset = try Data(contentsOf: outputURL("released")) == idlePNG
                    let suspendedPixelsReset = try Data(contentsOf: outputURL("suspended")) == idlePNG
                    let legacyPixelsReset = try Data(contentsOf: outputURL("legacy")) == idlePNG
                    poseChecksPassed = poseChecksPassed && distinct && releasedPixelsReset && suspendedPixelsReset && legacyPixelsReset
                    overlayEvidence = ["rendered": true, "A_B_SpaceImagesDistinct": distinct, "releasedPixelsMatchIdle": releasedPixelsReset, "suspendedPixelsMatchIdle": suspendedPixelsReset, "legacyPixelsMatchIdle": legacyPixelsReset, "simultaneousModifiersRendered": true, "fourteenSimultaneousKeysRendered": true, "decodedImageCacheLimit": 12, "syntheticWait": "CLI waits for the latest background composition; live frames never wait on image decoding"]
                }
                let report: [String: Any] = ["modelLoaded": true, "metalPipelineCreated": true, "drawables": model.drawableCount, "textures": model.textureURLs.count, "maskGroups": Set(idle.filter { !$0.masks.isEmpty }.map { $0.masks }).count, "poseChangedDrawables": changed, "leftOnlyChangedDrawables": leftChanged, "rightOnlyChangedDrawables": rightChanged, "middleHeldZeroPulseChangedDrawables": middleHeldChanged, "suspendedResetMatchesIdle": suspendedReset, "disabledResetMatchesIdle": disabledReset, "releasedResetMatchesIdle": releasedReset, "poseChecksPassed": poseChecksPassed, "keyboardAssetCount": model.keyboardOverlayURLs.count, "keyboardAssetsComplete": keyAssetsComplete, "legacyKeepsRaisedPaw": legacyKeepsRaisedPaw, "emptyKeysKeepRaisedPaw": emptyKeysKeepRaisedPaw, "pendingOverlayKeepsRaisedPaw": pendingOverlayKeepsRaisedPaw, "keyboardOverlayEvidence": overlayEvidence, "offscreenRendered": options.checkOutput != nil, "evidence": "synthetic model and Metal pipeline check; not real input monitoring or visual acceptance"]
                print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
                exit(poseChecksPassed ? 0 : 2)
            } catch { fputs("KeyTrailPet: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = PetApplication(options: options)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
