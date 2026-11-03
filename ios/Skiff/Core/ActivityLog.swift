import Foundation
import Observation

/** What Skiff sent to the TV, and how (Settings → Activity): the last 50, newest first, kept across launches. (ActivityLog.kt) */
@MainActor @Observable
final class ActivityLog {
    static let shared = ActivityLog()
    private static let max = 50
    private static let key = "activity.entries"

    /** `via`: "Pairing" or "USB debugging". `ok`: false when the TV couldn't be reached or said no. */
    struct Entry: Codable, Equatable, Identifiable {
        var t: Int64
        var w: String
        var v: String
        var ok: Bool
        var id: String { "\(t)-\(w)" }
        var time: Date { Date(timeIntervalSince1970: TimeInterval(t) / 1000) }
        var what: String { w }
        var via: String { v }
    }

    private(set) var entries: [Entry]

    private init() {
        entries = UserDefaults.standard.data(forKey: ActivityLog.key)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func add(_ what: String, via: String, ok: Bool = true) {
        entries.insert(Entry(t: nowMillis(), w: what, v: via, ok: ok), at: 0)
        if entries.count > ActivityLog.max { entries.removeLast(entries.count - ActivityLog.max) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: ActivityLog.key)
    }
}

/** The two ways to the TV, as the log keeps them. */
enum Via {
    static let pairing = "Pairing"
    static let adb = "USB debugging"
}
