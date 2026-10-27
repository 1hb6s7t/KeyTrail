import Foundation
import KeyTrailIPC

/// These messages stay inside the resident collector. They are never encoded,
/// logged or sent to the statistics store. The renderer receives only PetState.
enum PetAnimationEvent {
    case key(code: Int64, isDown: Bool, autorepeat: Bool)
    case mouse(button: Int, isDown: Bool)
    case gaze(x: Double, y: Double)
    case scroll
    case reset
}

/// Bounded, current-pose memory for the keyboard/mouse cat. No input history is
/// retained. A short pulse makes a tap visible even when down/up share one frame.
@MainActor
public final class PetAnimationState {
    private let clock: () -> TimeInterval
    private let pulseDuration: TimeInterval = 0.14
    private var heldKeys = Set<Int64>()
    // One expiry per supported physical key, never an ordered event queue.
    // Left/right modifiers remain independent even when a resource is shared.
    private var keyPulseUntil: [Int64: TimeInterval] = [:]
    private var buttons = 0
    private var leftUntil: TimeInterval = 0
    private var rightUntil: TimeInterval = 0
    private var gazeX = 0.0
    private var gazeY = 0.0
    private var revision: UInt64 = 0
    private var lastClock: TimeInterval = 0
    private var publishedEnabled: Bool?
    private var publishedSuspended: Bool?

    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    public func key(code: Int64, isDown: Bool, autorepeat: Bool = false) {
        // macOS virtual key codes fit in this fixed domain; arbitrary input
        // cannot grow the in-memory held set without bound.
        guard (0...255).contains(code), !autorepeat else { return }
        let now = monotonicNow()
        if isDown {
            guard heldKeys.insert(code).inserted else { return }
            leftUntil = now + pulseDuration
            if PetKeyboardKey.fromMacKeyCode(code) != nil { keyPulseUntil[code] = now + pulseDuration }
        } else {
            guard heldKeys.remove(code) != nil else { return }
        }
        revision &+= 1
    }

    public func mouse(button: Int, isDown: Bool) {
        guard (0...2).contains(button) else { return }
        let bit = 1 << button
        guard ((buttons & bit) != 0) != isDown else { return }
        if isDown { buttons |= bit; rightUntil = monotonicNow() + pulseDuration }
        else { buttons &= ~bit }
        revision &+= 1
    }

    /// Correct missed releases using current state, only for inputs already held.
    /// The caller applies permission and suspension gates before querying the OS.
    /// This never discovers presses, extends pulses or retains an input history.
    public func reconcileReleasedInputs(keyIsDown: (Int64) -> Bool, buttonIsDown: (Int) -> Bool) {
        let releasedKeys = heldKeys.filter { !keyIsDown($0) }
        var releasedButtons = 0
        for button in 0...2 where buttons & (1 << button) != 0 {
            if !buttonIsDown(button) { releasedButtons |= 1 << button }
        }
        guard !releasedKeys.isEmpty || releasedButtons != 0 else { return }
        heldKeys.subtract(releasedKeys)
        buttons &= ~releasedButtons
        revision &+= 1
    }

    public func scroll() {
        rightUntil = monotonicNow() + pulseDuration
        revision &+= 1
    }

    public func gaze(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        // A coarse normalized pose, never an absolute screen coordinate.
        let x = (min(1, max(-1, x)) * 64).rounded() / 64
        let y = (min(1, max(-1, y)) * 64).rounded() / 64
        guard x != gazeX || y != gazeY else { return }
        gazeX = x; gazeY = y; revision &+= 1
    }

    public func reset() {
        guard !heldKeys.isEmpty || !keyPulseUntil.isEmpty || buttons != 0 || leftUntil != 0 || rightUntil != 0 || gazeX != 0 || gazeY != 0 else { return }
        heldKeys.removeAll(keepingCapacity: true)
        keyPulseUntil.removeAll(keepingCapacity: true)
        buttons = 0; leftUntil = 0; rightUntil = 0; gazeX = 0; gazeY = 0
        revision &+= 1
    }

    public func snapshot(enabled: Bool, suspended: Bool) -> PetState {
        if !enabled || suspended { reset() }
        if publishedEnabled != enabled || publishedSuspended != suspended {
            publishedEnabled = enabled; publishedSuspended = suspended; revision &+= 1
        }
        let now = monotonicNow()
        if leftUntil > 0 && leftUntil <= now { leftUntil = 0; revision &+= 1 }
        if rightUntil > 0 && rightUntil <= now { rightUntil = 0; revision &+= 1 }
        let livePulses = keyPulseUntil.filter { $0.value > now }
        if livePulses.count != keyPulseUntil.count { keyPulseUntil = livePulses; revision &+= 1 }
        var visualKeys: [String: PetKeyboardKey] = [:]
        for code in heldKeys.union(keyPulseUntil.keys) {
            if let key = PetKeyboardKey.fromMacKeyCode(code) { visualKeys[key.rawValue] = key }
        }
        var result = PetState(enabled: enabled, suspended: suspended,
                        leftPawHeld: !heldKeys.isEmpty, rightPawHeld: buttons != 0,
                        leftPulseRemainingMs: remaining(leftUntil, now: now),
                        rightPulseRemainingMs: remaining(rightUntil, now: now),
                        mouseButtonsMask: buttons, gazeX: gazeX, gazeY: gazeY,
                        revision: revision)
        result.keyboardKeys = visualKeys.values.sorted { $0.rawValue < $1.rawValue }
        return result
    }

    private func monotonicNow() -> TimeInterval {
        let value = clock()
        if value.isFinite { lastClock = max(lastClock, value) }
        return lastClock
    }
    private func remaining(_ until: TimeInterval, now: TimeInterval) -> Int {
        Int(min(140, max(0, ceil((until - now) * 1000))))
    }
}
