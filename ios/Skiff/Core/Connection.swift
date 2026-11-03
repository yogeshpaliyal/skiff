import Foundation

/**
 * How each TV is reached, for the remote and for links (Settings): Automatic (the TV's ADB when this phone is allowed,
 * else paired: the Google TV remote protocol), Pairing only, or USB debugging (ADB) only. (Connection.kt)
 */
enum Connection {
    enum Mode: String, CaseIterable, Identifiable {
        case auto = "AUTO", pairing = "PAIRING", adb = "ADB"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: return "Automatic"
            case .pairing: return "Pairing"
            case .adb: return "USB debugging"
            }
        }
    }

    static func remote(_ host: String) -> Mode { get("remote:", host) }
    static func setRemote(_ host: String, _ m: Mode) { set("remote:", host, m) }
    static func link(_ host: String) -> Mode { get("link:", host) }
    static func setLink(_ host: String, _ m: Mode) { set("link:", host, m) }

    private static func get(_ kind: String, _ host: String) -> Mode {
        UserDefaults.standard.string(forKey: "connection." + kind + host.trimmed).flatMap(Mode.init(rawValue:)) ?? .auto
    }

    private static func set(_ kind: String, _ host: String, _ m: Mode) {
        UserDefaults.standard.set(m.rawValue, forKey: "connection." + kind + host.trimmed)
    }
}
