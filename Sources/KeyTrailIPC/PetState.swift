import Foundation

/// Ephemeral current pose only. Physical key overlay identifiers describe a
/// bounded current set, not ordered events, text, or a persistent sequence.
public struct PetState: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var suspended: Bool
    public var leftPawHeld: Bool
    public var rightPawHeld: Bool
    public var leftPulseRemainingMs: Int
    public var rightPulseRemainingMs: Int
    public var mouseButtonsMask: Int
    public var gazeX: Double
    public var gazeY: Double
    public var revision: UInt64
    /// nil identifies a pre-key-mapping collector. Never fall back to Space.
    public var keyboardKeys: [PetKeyboardKey]?

    public init(enabled: Bool = false, suspended: Bool = false,
                leftPawHeld: Bool = false, rightPawHeld: Bool = false,
                leftPulseRemainingMs: Int = 0, rightPulseRemainingMs: Int = 0,
                mouseButtonsMask: Int = 0, gazeX: Double = 0, gazeY: Double = 0,
                revision: UInt64 = 0, keyboardKeys: [PetKeyboardKey]? = []) {
        self.enabled = enabled; self.suspended = suspended
        self.leftPawHeld = leftPawHeld; self.rightPawHeld = rightPawHeld
        self.leftPulseRemainingMs = leftPulseRemainingMs; self.rightPulseRemainingMs = rightPulseRemainingMs
        self.mouseButtonsMask = mouseButtonsMask
        self.gazeX = gazeX; self.gazeY = gazeY; self.revision = revision
        self.keyboardKeys = keyboardKeys
    }
}
