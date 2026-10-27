import Foundation
import KeyTrailIPC
import KeyTrailRuntime

private struct CheckFailure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(message: message) }
}
private final class TestClock { var now: TimeInterval = 100 }

@main
struct PetChecks {
    @MainActor static func main() throws {
        let clock = TestClock()
        let state = PetAnimationState(clock: { clock.now })
        func snapshot() -> PetState { state.snapshot(enabled: true, suspended: false) }
        func neutral(_ value: PetState) -> Bool {
            !value.leftPawHeld && !value.rightPawHeld && value.mouseButtonsMask == 0 &&
            value.leftPulseRemainingMs == 0 && value.rightPulseRemainingMs == 0 &&
            value.gazeX == 0 && value.gazeY == 0 && value.keyboardKeys == []
        }
        let initial = snapshot()
        try require(neutral(initial), "Initial pose is not neutral")
        try require(snapshot().revision == initial.revision, "Idle polling changed revision")
        print("PASS Initial pose and idle polling are stable")

        state.key(code: 0, isDown: true)
        let held = snapshot()
        try require(held.leftPawHeld && !held.rightPawHeld && held.leftPulseRemainingMs == 140, "Keyboard did not animate only the left paw")
        state.key(code: 0, isDown: false)
        let tapped = snapshot()
        try require(!tapped.leftPawHeld && tapped.leftPulseRemainingMs > 0, "Short down/up disappeared before renderer polling")
        clock.now += 0.15
        let expired = snapshot()
        try require(expired.leftPulseRemainingMs == 0 && expired.revision > tapped.revision, "Pulse expiration did not publish neutral pose")
        try require(snapshot().revision == expired.revision, "Expired pulse changed every poll")
        print("PASS Short taps survive a render interval and expire without repeated revisions")

        state.key(code: 0, isDown: true)
        let firstDown = snapshot()
        clock.now += 0.05
        state.key(code: 0, isDown: true)
        state.key(code: 0, isDown: true, autorepeat: true)
        state.key(code: -1, isDown: true)
        state.key(code: 256, isDown: true)
        let duplicated = snapshot()
        try require(duplicated.revision == firstDown.revision && duplicated.leftPulseRemainingMs < firstDown.leftPulseRemainingMs, "Duplicate, repeat or invalid key extended the pulse")
        state.key(code: 1, isDown: true)
        state.key(code: 0, isDown: false)
        try require(snapshot().leftPawHeld, "Releasing one key released another held key")
        state.key(code: 1, isDown: false)
        try require(!snapshot().leftPawHeld, "Final key release left the paw stuck")
        let released = snapshot().revision
        state.key(code: 1, isDown: false)
        try require(snapshot().revision == released, "Duplicate release changed state")
        print("PASS Overlapping keys, duplicate presses, repeats and bounded key codes")

        state.reset()
        for button in 0...2 { state.mouse(button: button, isDown: true) }
        let allButtons = snapshot()
        try require(allButtons.mouseButtonsMask == 7 && allButtons.rightPawHeld && !allButtons.leftPawHeld, "Mouse combinations did not animate the right paw")
        state.mouse(button: 1, isDown: false)
        try require(snapshot().mouseButtonsMask == 5 && snapshot().rightPawHeld, "Mouse release cleared other held buttons")
        let mouseRevision = snapshot().revision
        state.mouse(button: 1, isDown: false)
        state.mouse(button: -1, isDown: true)
        state.mouse(button: 3, isDown: true)
        try require(snapshot().revision == mouseRevision, "Invalid or duplicate mouse input changed state")
        state.mouse(button: 0, isDown: false)
        state.mouse(button: 2, isDown: false)
        try require(!snapshot().rightPawHeld, "Mouse release left a stuck paw")
        state.reset(); state.scroll()
        let scrolled = snapshot()
        try require(!scrolled.rightPawHeld && scrolled.mouseButtonsMask == 0 && scrolled.rightPulseRemainingMs > 0, "Scroll pretended a button was held")
        print("PASS Simultaneous mouse buttons and scroll-only pulses")

        state.key(code: 255, isDown: true)
        state.mouse(button: 0, isDown: true)
        state.gaze(x: 0.5, y: -0.5)
        let disabled = state.snapshot(enabled: false, suspended: false)
        try require(!disabled.enabled && neutral(disabled), "Disabling pet retained transient input")
        try require(neutral(snapshot()), "Re-enabling replayed old input")
        state.key(code: 0, isDown: true); state.scroll(); state.gaze(x: 1, y: 1)
        let suspended = state.snapshot(enabled: true, suspended: true)
        try require(suspended.suspended && neutral(suspended), "Suspension retained transient input")
        try require(neutral(snapshot()), "Resume replayed pre-suspension input")
        state.reset()
        let resetRevision = snapshot().revision
        state.reset()
        try require(snapshot().revision == resetRevision, "Repeated neutral resets changed revision")
        print("PASS Disabled and suspended snapshots clear pose without replay")

        state.gaze(x: 10, y: -10)
        try require(snapshot().gazeX == 1 && snapshot().gazeY == -1, "Normalized gaze exceeded bounds")
        state.gaze(x: 0.501, y: -0.501)
        let quantized = snapshot()
        try require(quantized.gazeX == 0.5 && quantized.gazeY == -0.5, "Gaze was not quantized")
        state.gaze(x: 0.502, y: -0.502)
        state.gaze(x: .nan, y: 0)
        state.gaze(x: 0, y: .infinity)
        try require(snapshot().revision == quantized.revision, "Same gaze bin or non-finite gaze changed state")
        print("PASS Gaze clamping, coarse pose quantization and non-finite rejection")

        state.reset(); state.key(code: 0, isDown: true); state.key(code: 0, isDown: false)
        clock.now += 0.2
        try require(snapshot().leftPulseRemainingMs == 0, "Pulse did not expire before clock rollback")
        clock.now -= 10
        try require(snapshot().leftPulseRemainingMs == 0, "Clock rollback revived an expired pulse")
        state.scroll()
        let beforeInvalidClock = snapshot()
        clock.now = .nan
        try require(snapshot().rightPulseRemainingMs == beforeInvalidClock.rightPulseRemainingMs, "Non-finite clock changed pose")
        clock.now = 200
        try require(snapshot().rightPulseRemainingMs == 0, "Valid later time did not expire pulse")
        print("PASS Monotonic expiry remains bounded across clock rollback and invalid readings")

        state.key(code: 42, isDown: true); state.mouse(button: 2, isDown: true); state.gaze(x: 0.25, y: 0.75)
        let encoded = try JSONEncoder().encode(snapshot())
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let allowed: Set<String> = ["enabled", "suspended", "leftPawHeld", "rightPawHeld", "leftPulseRemainingMs", "rightPulseRemainingMs", "mouseButtonsMask", "gazeX", "gazeY", "revision", "keyboardKeys"]
        try require(Set(object.keys) == allowed, "Renderer state exposed unexpected input fields")
        let decoded = try JSONDecoder().decode(PetState.self, from: encoded)
        try require(decoded == snapshot(), "Pet state failed Codable round-trip")
        print("PASS Renderer contract contains only current semantic pose and round-trips")
        let legacyPreferences = try JSONDecoder().decode(RuntimePreferences.self, from: Data("{}".utf8))
        try require(!legacyPreferences.petEnabled, "Old settings implicitly enabled the pet")
        var legacyDetails = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RuntimeDetails())) as? [String: Any] ?? [:]
        legacyDetails.removeValue(forKey: "petAvailable")
        legacyDetails["preferences"] = ["floatingWindowEnabled": true]
        let oldCollector = try JSONDecoder().decode(RuntimeDetails.self, from: JSONSerialization.data(withJSONObject: legacyDetails))
        try require(oldCollector.petAvailable == nil && !oldCollector.preferences.petEnabled && oldCollector.preferences.floatingWindowEnabled, "Old collector settings failed compatibility decode")
        print("PASS Old collector settings preserve existing values and default pet capability to unavailable")
        var legacyPose = object
        legacyPose.removeValue(forKey: "keyboardKeys")
        let legacySnapshot = try JSONDecoder().decode(PetState.self, from: JSONSerialization.data(withJSONObject: legacyPose))
        try require(legacySnapshot.keyboardKeys == nil, "Legacy collector must remain distinguishable from a neutral current collector")
        try require(PetState().keyboardKeys == [], "New pose should default to a supported, empty keyboard set")
        print("PASS Legacy missing keyboard field decodes nil; new pose supports an empty set")

        let keyClock = TestClock()
        let keys = PetAnimationState(clock: { keyClock.now })
        func keySnapshot() -> PetState { keys.snapshot(enabled: true, suspended: false) }
        func names() -> [String] { keySnapshot().keyboardKeys?.map(\.rawValue) ?? [] }
        keys.key(code: 49, isDown: true); keys.key(code: 11, isDown: true); keys.key(code: 0, isDown: true)
        try require(names() == ["KeyA", "KeyB", "Space"], "A, B and Space did not remain distinct in stable resource order")
        keyClock.now += 0.2
        try require(names() == ["KeyA", "KeyB", "Space"], "Held keys disappeared after their short pulses expired")
        keys.key(code: 11, isDown: false)
        try require(names() == ["KeyA", "Space"], "Releasing B removed another held key")
        keys.reset()
        keys.key(code: 255, isDown: true); keys.key(code: 255, isDown: false)
        try require(names().isEmpty, "Unsupported key falsely mapped to Space or another key")
        print("PASS A/B/Space distinction, canonical set ordering, held release and no unsupported fallback")

        keys.reset()
        for code in [Int64(56), 60, 59, 62, 58, 61] { keys.key(code: code, isDown: true) }
        try require(names() == ["AltLeft", "AltRight", "ControlLeft", "ControlRight", "ShiftLeft", "ShiftRight"], "Left/right modifier resources were conflated")
        keyClock.now += 0.2
        keys.key(code: 56, isDown: false)
        try require(!names().contains("ShiftLeft") && names().contains("ShiftRight"), "Left Shift release incorrectly released Right Shift")
        keys.reset()
        keys.key(code: 54, isDown: true); keys.key(code: 55, isDown: true)
        try require(names() == ["Meta"], "Shared Command resource was not deduplicated")
        keyClock.now += 0.2; keys.key(code: 54, isDown: false)
        try require(names() == ["Meta"], "One Command release incorrectly removed the other held Command")
        keys.key(code: 55, isDown: false)
        try require(names().isEmpty, "Final Command release left a stale resource")
        print("PASS Independent left/right modifiers and shared-resource hold ownership")

        keys.reset()
        keys.key(code: 0, isDown: true); keys.key(code: 0, isDown: false)
        keyClock.now += 0.08
        keys.key(code: 11, isDown: true); keys.key(code: 11, isDown: false)
        try require(names() == ["KeyA", "KeyB"], "Overlapping short pulses lost a key")
        keyClock.now += 0.08
        try require(names() == ["KeyB"], "A did not expire independently while B remained visible")
        keyClock.now += 0.08
        try require(names().isEmpty, "B did not expire independently")
        keys.key(code: 0, isDown: true)
        keyClock.now += 0.1
        keys.key(code: 0, isDown: true); keys.key(code: 0, isDown: true, autorepeat: true)
        keys.key(code: 0, isDown: false)
        keyClock.now += 0.05
        try require(names().isEmpty, "Duplicate down or autorepeat extended an individual key pulse")
        print("PASS Per-key pulse expiry remains independent and repeats do not extend it")

        keys.key(code: 0, isDown: true); keys.key(code: 11, isDown: true); keys.key(code: 11, isDown: false)
        try require(keys.snapshot(enabled: true, suspended: true).keyboardKeys == [], "Suspension retained held/pulsed key resources")
        try require(names().isEmpty, "Resume replayed a pre-suspension key resource")
        keys.key(code: 49, isDown: true); keys.key(code: 49, isDown: false)
        try require(keys.snapshot(enabled: false, suspended: false).keyboardKeys == [], "Disable retained a key pulse")
        try require(names().isEmpty, "Re-enable replayed a disabled key resource")
        keys.key(code: 0, isDown: true); keys.reset()
        try require(names().isEmpty, "Explicit reset retained a key resource")
        print("PASS Suspension, disable and explicit reset purge held keys and each short pulse")

        let releaseClock = TestClock()
        let releaseState = PetAnimationState(clock: { releaseClock.now })
        func releaseSnapshot() -> PetState { releaseState.snapshot(enabled: true, suspended: false) }
        func releaseNames() -> [String] { releaseSnapshot().keyboardKeys?.map(\.rawValue) ?? [] }
        _ = releaseSnapshot()
        releaseState.key(code: 0, isDown: true)
        releaseState.mouse(button: 0, isDown: true)
        releaseClock.now += 10
        _ = releaseSnapshot()
        releaseState.reconcileReleasedInputs(keyIsDown: { _ in false }, buttonIsDown: { _ in false })
        let corrected = releaseSnapshot()
        try require(neutral(corrected), "Missing keyUp or mouseUp left a stale held pose")
        var queriedKeys = Set<Int64>()
        var queriedButtons = Set<Int>()
        releaseState.reconcileReleasedInputs(keyIsDown: { queriedKeys.insert($0); return true }, buttonIsDown: { queriedButtons.insert($0); return true })
        try require(queriedKeys.isEmpty && queriedButtons.isEmpty, "Neutral reconciliation scanned inputs or discovered a new press")
        try require(releaseSnapshot().revision == corrected.revision, "Neutral reconciliation changed revision")
        print("PASS Missing releases recover and neutral reconciliation neither queries nor changes pose")

        releaseState.key(code: 0, isDown: true)
        releaseState.key(code: 11, isDown: true)
        releaseState.mouse(button: 0, isDown: true)
        releaseState.mouse(button: 2, isDown: true)
        releaseClock.now += 86_400
        let longHeld = releaseSnapshot()
        releaseState.reconcileReleasedInputs(keyIsDown: { queriedKeys.insert($0); return true }, buttonIsDown: { queriedButtons.insert($0); return true })
        try require(releaseSnapshot() == longHeld, "Reconciliation timed out a genuine long hold or changed its revision")
        try require(queriedKeys == [0, 11] && queriedButtons == [0, 2], "Reconciliation queried inputs outside the held candidates")
        releaseState.reconcileReleasedInputs(keyIsDown: { $0 == 11 }, buttonIsDown: { $0 == 2 })
        let partiallyHeld = releaseSnapshot()
        try require(partiallyHeld.leftPawHeld && releaseNames() == ["KeyB"] && partiallyHeld.mouseButtonsMask == 4 && partiallyHeld.rightPawHeld, "Partial release removed another genuine hold")
        try require(partiallyHeld.revision == longHeld.revision + 1, "One release reconciliation did not publish exactly one change")
        releaseState.reconcileReleasedInputs(keyIsDown: { _ in true }, buttonIsDown: { _ in true })
        try require(releaseSnapshot().revision == partiallyHeld.revision, "Unchanged held inputs caused revision churn")
        print("PASS Real long holds survive while partial key/button releases publish one bounded change")

        releaseState.reset()
        for code in [Int64(54), 55, 56, 60] { releaseState.key(code: code, isDown: true) }
        releaseClock.now += 0.2
        releaseState.reconcileReleasedInputs(keyIsDown: { $0 == 55 || $0 == 60 }, buttonIsDown: { _ in false })
        try require(releaseNames() == ["Meta", "ShiftRight"], "Reconciliation conflated left/right modifier ownership")
        releaseState.reconcileReleasedInputs(keyIsDown: { $0 == 60 }, buttonIsDown: { _ in false })
        try require(releaseNames() == ["ShiftRight"], "Final Command release retained its shared resource")
        releaseState.reconcileReleasedInputs(keyIsDown: { _ in false }, buttonIsDown: { _ in false })
        try require(neutral(releaseSnapshot()), "Final modifier release left the keyboard paw held")
        print("PASS Reconciled modifiers preserve independent sides and shared Command ownership")

        releaseState.key(code: 0, isDown: true)
        releaseState.mouse(button: 1, isDown: true)
        releaseClock.now += 0.05
        let beforePulseRelease = releaseSnapshot()
        releaseState.reconcileReleasedInputs(keyIsDown: { _ in false }, buttonIsDown: { _ in false })
        let pulseReleased = releaseSnapshot()
        try require(!pulseReleased.leftPawHeld && !pulseReleased.rightPawHeld && pulseReleased.mouseButtonsMask == 0, "Release correction retained held state during a short pulse")
        try require(pulseReleased.leftPulseRemainingMs == beforePulseRelease.leftPulseRemainingMs && pulseReleased.rightPulseRemainingMs == beforePulseRelease.rightPulseRemainingMs && releaseNames() == ["KeyA"], "Release correction erased or extended an in-flight short pulse")
        queriedKeys.removeAll(); queriedButtons.removeAll()
        releaseState.reconcileReleasedInputs(keyIsDown: { queriedKeys.insert($0); return true }, buttonIsDown: { queriedButtons.insert($0); return true })
        try require(queriedKeys.isEmpty && queriedButtons.isEmpty && releaseSnapshot().revision == pulseReleased.revision, "Pulse-only reconciliation queried new inputs or changed revision")
        releaseClock.now += 0.1
        let pulseFinished = releaseSnapshot()
        try require(neutral(pulseFinished), "Reconciled release extended a pulse beyond its original expiry")
        releaseState.reconcileReleasedInputs(keyIsDown: { _ in true }, buttonIsDown: { _ in true })
        try require(releaseSnapshot().revision == pulseFinished.revision, "Expired pulse reconciliation caused idle churn")
        print("PASS Release correction preserves original short pulses without extending or re-querying them")
        print("Pet checks passed (synthetic in-memory state only; no permissions, event injection, collection or persistence)")
    }
}
