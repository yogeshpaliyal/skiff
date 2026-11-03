import Foundation

/**
 * Android's key codes (KeyEvent.KEYCODE_*): both ways to the TV use them, the remote protocol and `input keyevent`.
 * And text as key presses, for a TV that hasn't said which field has focus (Android's virtual keyboard map, for the
 * characters a search box takes).
 */
enum Key {
    static let home = 3
    static let back = 4
    static let dpadUp = 19
    static let dpadDown = 20
    static let dpadLeft = 21
    static let dpadRight = 22
    static let dpadCenter = 23
    static let volumeUp = 24
    static let volumeDown = 25
    static let power = 26
    static let shiftLeft = 59
    static let del = 67
    static let menu = 82
    static let mediaPlayPause = 85
    static let mediaRewind = 89
    static let mediaFastForward = 90
    static let volumeMute = 164

    /** "DPAD_UP", for the Activity log (KeyEvent.keyCodeToString without its prefix). */
    static func name(_ code: Int) -> String {
        switch code {
        case home: return "HOME"
        case back: return "BACK"
        case dpadUp: return "DPAD_UP"
        case dpadDown: return "DPAD_DOWN"
        case dpadLeft: return "DPAD_LEFT"
        case dpadRight: return "DPAD_RIGHT"
        case dpadCenter: return "DPAD_CENTER"
        case volumeUp: return "VOLUME_UP"
        case volumeDown: return "VOLUME_DOWN"
        case power: return "POWER"
        case del: return "DEL"
        case menu: return "MENU"
        case mediaPlayPause: return "MEDIA_PLAY_PAUSE"
        case mediaRewind: return "MEDIA_REWIND"
        case mediaFastForward: return "MEDIA_FAST_FORWARD"
        case volumeMute: return "VOLUME_MUTE"
        default: return "\(code)"
        }
    }

    /** One character as a key press: its key code, and whether Shift is held. Nil when the keyboard has no key for it. */
    static func forCharacter(_ c: Character) -> (code: Int, shift: Bool)? {
        if let a = c.asciiValue {
            switch a {
            case 97...122: return (29 + Int(a - 97), false)      // a–z: KEYCODE_A = 29
            case 65...90: return (29 + Int(a - 65), true)        // A–Z
            case 48...57: return (7 + Int(a - 48), false)        // 0–9: KEYCODE_0 = 7
            default: break
            }
        }
        let table: [Character: (Int, Bool)] = [
            " ": (62, false), "\n": (66, false), "\t": (61, false),
            ",": (55, false), ".": (56, false), "`": (68, false), "-": (69, false), "=": (70, false),
            "[": (71, false), "]": (72, false), "\\": (73, false), ";": (74, false), "'": (75, false), "/": (76, false),
            "@": (77, false), "+": (81, false), "*": (17, false), "#": (18, false),
            "!": (8, true), "$": (11, true), "%": (12, true), "^": (13, true), "&": (14, true),
            "(": (16, true), ")": (7, true), "_": (69, true), "{": (71, true), "}": (72, true), "|": (73, true),
            ":": (74, true), "\"": (75, true), "<": (55, true), ">": (56, true), "?": (76, true), "~": (68, true),
        ]
        return table[c].map { (code: $0.0, shift: $0.1) }
    }
}
