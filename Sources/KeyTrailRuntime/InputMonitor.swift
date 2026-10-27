import AppKit
import Carbon
import CoreGraphics
import KeyTrailCore

/// Passive, local input statistics. Key labels are physical positions, never translated text.
final class InputMonitor {
    var onSample: ((InputSample) -> Void)?
    var onInterruption: ((String) -> Void)?
    var onPetInput: ((PetAnimationEvent) -> Void)?
    var petInputEnabled = false { didSet { if !petInputEnabled { onPetInput?(.reset) } } }
    private var lastPetGazeTime: TimeInterval = 0
    var suspended = false { didSet { if suspended { resetAnchors() } } }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var previousPosition: CGPoint?
    private var heldModifiers = Set<Int64>()
    var hasPermission: Bool { CGPreflightListenEventAccess() }
    var secureInputEnabled: Bool { IsSecureEventInputEnabled() }

    func start() -> Bool {
        if tap != nil { return true }
        guard hasPermission else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.receive(type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = newTap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        resetAnchors()
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; resetAnchors()
    }

    func resetAnchors() {
        previousPosition = nil; heldModifiers.removeAll(); lastPetGazeTime = 0
        onPetInput?(.reset)
    }

    /// Correct missed releases using current session state, never by expiring a
    /// genuine hold or discovering new presses. Only the authorized collector
    /// performs these reads; no extra listener or input history is introduced.
    @MainActor
    func reconcilePetInputs(_ state: PetAnimationState) {
        guard petInputEnabled, tap != nil, !suspended, !secureInputEnabled, hasPermission else {
            state.reset()
            return
        }
        func keyIsDown(_ code: Int64) -> Bool {
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
        heldModifiers = heldModifiers.filter { keyIsDown($0) }
        state.reconcileReleasedInputs(keyIsDown: keyIsDown, buttonIsDown: { button in
            guard let value = CGMouseButton(rawValue: UInt32(button)) else { return false }
            return CGEventSource.buttonState(.combinedSessionState, button: value)
        })
    }

    private func receive(_ type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout {
            resetAnchors()
            onInterruption?("监听超时 · 采集已暂停，请重新开始")
            return
        }
        if type == .tapDisabledByUserInput {
            resetAnchors()
            onInterruption?("系统暂停了输入监听，请检查权限后重新开始")
            return
        }
        guard !suspended, !secureInputEnabled else { resetAnchors(); return }
        // Locally posted events can be identified by their source process; exclude our own.
        guard event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(ProcessInfo.processInfo.processIdentifier) else { return }
        let now = Date()
        switch type {
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if petInputEnabled { onPetInput?(.key(code: code, isDown: true, autorepeat: false)) }
            onSample?(InputSample(timestamp: now, kind: .keyPress, keyLabel: Self.keyLabel(code)))
        case .keyUp:
            if petInputEnabled { onPetInput?(.key(code: event.getIntegerValueField(.keyboardEventKeycode), isDown: false, autorepeat: false)) }
        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            guard [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code) else { return }
            // Caps Lock changes its latched state once per press, on either transition.
            if code == 57 {
                if petInputEnabled {
                    onPetInput?(.key(code: code, isDown: true, autorepeat: false))
                    onPetInput?(.key(code: code, isDown: false, autorepeat: false))
                }
                onSample?(InputSample(timestamp: now, kind: .keyPress, keyLabel: "Caps"))
                return
            }
            let isDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
            if petInputEnabled { onPetInput?(.key(code: code, isDown: isDown, autorepeat: false)) }
            if !isDown { heldModifiers.remove(code) }
            else if !heldModifiers.contains(code) {
                heldModifiers.insert(code)
                onSample?(InputSample(timestamp: now, kind: .keyPress, keyLabel: Self.keyLabel(code)))
            }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let point = event.location
            updatePetGaze(point)
            defer { previousPosition = point }
            guard let previousPosition else { return }
            let distance = hypot(point.x - previousPosition.x, point.y - previousPosition.y)
            // Treat very large jumps as a coordinate discontinuity; never call this physical distance.
            guard distance > 0, distance <= 2_000 else { return }
            onSample?(InputSample(timestamp: now, kind: .mouseMove, distancePoints: distance))
        case .leftMouseDown:
            if petInputEnabled { onPetInput?(.mouse(button: 0, isDown: true)) }; updatePetGaze(event.location)
            onSample?(InputSample(timestamp: now, kind: .leftClick))
        case .rightMouseDown:
            if petInputEnabled { onPetInput?(.mouse(button: 1, isDown: true)) }; updatePetGaze(event.location)
            onSample?(InputSample(timestamp: now, kind: .rightClick))
        case .otherMouseDown:
            if event.getIntegerValueField(.mouseEventButtonNumber) == 2 {
                if petInputEnabled { onPetInput?(.mouse(button: 2, isDown: true)) }; updatePetGaze(event.location)
                onSample?(InputSample(timestamp: now, kind: .middleClick))
            }
        case .leftMouseUp:
            if petInputEnabled { onPetInput?(.mouse(button: 0, isDown: false)) }
        case .rightMouseUp:
            if petInputEnabled { onPetInput?(.mouse(button: 1, isDown: false)) }
        case .otherMouseUp:
            if petInputEnabled && event.getIntegerValueField(.mouseEventButtonNumber) == 2 { onPetInput?(.mouse(button: 2, isDown: false)) }
        case .scrollWheel:
            let delta = abs(event.getDoubleValueField(.scrollWheelEventDeltaAxis1)) + abs(event.getDoubleValueField(.scrollWheelEventDeltaAxis2))
            if delta > 0 {
                if petInputEnabled { onPetInput?(.scroll) }
                onSample?(InputSample(timestamp: now, kind: .scroll, scrollDelta: delta))
            }
        default: break
        }
    }

    private func updatePetGaze(_ point: CGPoint) {
        guard petInputEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPetGazeTime >= 1.0 / 30 else { return }
        lastPetGazeTime = now
        var display = CGMainDisplayID(), count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return }
        let bounds = CGDisplayBounds(display)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let x = (point.x - bounds.minX) / bounds.width * 2 - 1
        let y = 1 - (point.y - bounds.minY) / bounds.height * 2
        onPetInput?(.gaze(x: x, y: y))
    }

    static func keyLabel(_ code: Int64) -> String {
        let labels: [Int64: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",51:"Delete",53:"Esc",54:"Cmd",55:"Cmd",56:"Shift",57:"Caps",58:"Option",59:"Ctrl",60:"Shift",61:"Option",62:"Ctrl",63:"Fn",64:"F17",65:"Num .",67:"Num *",69:"Num +",71:"Clear",75:"Num /",76:"Num Enter",78:"Num -",81:"Num =",82:"Num 0",83:"Num 1",84:"Num 2",85:"Num 3",86:"Num 4",87:"Num 5",88:"Num 6",89:"Num 7",91:"Num 8",92:"Num 9",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",113:"F15",114:"Help",115:"Home",116:"PageUp",117:"ForwardDelete",118:"F4",119:"End",120:"F2",121:"PageDown",122:"F1",123:"Left",124:"Right",125:"Down",126:"Up"]
        return labels[code] ?? "Key \(code)"
    }
}
