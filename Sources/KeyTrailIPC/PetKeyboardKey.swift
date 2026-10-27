import Foundation

/// Closed identifiers for the pinned standard BongoCat overlay assets. These
/// identify physical keys currently held or in a short animation pulse, never
/// committed text. They are used only by the local ephemeral pet snapshot.
public enum PetKeyboardKey: String, Codable, CaseIterable, Sendable {
    case altLeft = "AltLeft", altRight = "AltRight"
    case backQuote = "BackQuote", backspace = "Backspace", capsLock = "CapsLock"
    case controlLeft = "ControlLeft", controlRight = "ControlRight"
    case delete = "Delete", enter = "Enter", escape = "Escape", fn = "Fn"
    case keyA = "KeyA", keyB = "KeyB", keyC = "KeyC", keyD = "KeyD", keyE = "KeyE"
    case keyF = "KeyF", keyG = "KeyG", keyH = "KeyH", keyI = "KeyI", keyJ = "KeyJ"
    case keyK = "KeyK", keyL = "KeyL", keyM = "KeyM", keyN = "KeyN", keyO = "KeyO"
    case keyP = "KeyP", keyQ = "KeyQ", keyR = "KeyR", keyS = "KeyS", keyT = "KeyT"
    case keyU = "KeyU", keyV = "KeyV", keyW = "KeyW", keyX = "KeyX", keyY = "KeyY", keyZ = "KeyZ"
    case meta = "Meta"
    case num0 = "Num0", num1 = "Num1", num2 = "Num2", num3 = "Num3", num4 = "Num4"
    case num5 = "Num5", num6 = "Num6", num7 = "Num7", num8 = "Num8", num9 = "Num9"
    case shiftLeft = "ShiftLeft", shiftRight = "ShiftRight", slash = "Slash", space = "Space", tab = "Tab"

    /// Apple's hardware virtual key codes, not translated characters. Unsupported
    /// physical keys deliberately produce no overlay; never substitute Space.
    public static func fromMacKeyCode(_ code: Int64) -> PetKeyboardKey? {
        switch code {
        case 0: return .keyA; case 1: return .keyS; case 2: return .keyD
        case 3: return .keyF; case 4: return .keyH; case 5: return .keyG
        case 6: return .keyZ; case 7: return .keyX; case 8: return .keyC
        case 9: return .keyV; case 11: return .keyB; case 12: return .keyQ
        case 13: return .keyW; case 14: return .keyE; case 15: return .keyR
        case 16: return .keyY; case 17: return .keyT
        case 18: return .num1; case 19: return .num2; case 20: return .num3
        case 21: return .num4; case 22: return .num6; case 23: return .num5
        case 25: return .num9; case 26: return .num7; case 28: return .num8
        case 29: return .num0; case 31: return .keyO; case 32: return .keyU
        case 34: return .keyI; case 35: return .keyP; case 36: return .enter
        case 37: return .keyL; case 38: return .keyJ; case 40: return .keyK
        case 44: return .slash; case 45: return .keyN; case 46: return .keyM
        case 48: return .tab; case 49: return .space; case 50: return .backQuote
        case 51: return .backspace; case 53: return .escape
        case 54, 55: return .meta // Upstream provides one Command/Windows image.
        case 56: return .shiftLeft; case 57: return .capsLock; case 58: return .altLeft
        case 59: return .controlLeft; case 60: return .shiftRight; case 61: return .altRight
        case 62: return .controlRight; case 63: return .fn; case 117: return .delete
        default: return nil
        }
    }
}
