import Foundation
import Observation

/**
 * Every title you've used (shared, pasted or played), and the ones saved for later. One entry per title: using it
 * again moves it to the top and keeps its latest season and episode. Stored on the phone, in a small JSON file with
 * the same fields as the Android app's library.json. Main actor only (the file is tiny). (Library.kt)
 */
@MainActor @Observable
final class Library {
    static let shared = Library()

    struct Entry: Codable, Equatable, Identifiable {
        var imdbId: String
        var name: String
        var series: Bool
        var season: Int = 1
        var episode: Int = 1
        var poster: String? = nil
        var year: String? = nil
        var saved: Bool = false
        var inHistory: Bool = true      // false: only saved for later
        var plays: Int = 0
        var lastUsed: Int64 = nowMillis()
        var link: String? = nil         // a link (JioHotstar, YouTube…): then imdbId is the link itself
        var app: String? = nil          // the TV app it opened in ("JioHotstar")

        var id: String { imdbId }
        var title: Title { Title(imdbId: imdbId, name: name, series: series, season: season, episode: episode) }

        // Android writes "" for a missing value: read both.
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            func s(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k))?.nonBlank }
            imdbId = try c.decode(String.self, forKey: .imdbId)
            name = s(.name) ?? ""
            series = (try? c.decodeIfPresent(Bool.self, forKey: .series)) ?? false
            season = (try? c.decodeIfPresent(Int.self, forKey: .season)) ?? 1
            episode = (try? c.decodeIfPresent(Int.self, forKey: .episode)) ?? 1
            poster = s(.poster)
            year = s(.year)
            saved = (try? c.decodeIfPresent(Bool.self, forKey: .saved)) ?? false
            inHistory = (try? c.decodeIfPresent(Bool.self, forKey: .inHistory)) ?? true
            plays = (try? c.decodeIfPresent(Int.self, forKey: .plays)) ?? 0
            lastUsed = (try? c.decodeIfPresent(Int64.self, forKey: .lastUsed)) ?? 0
            link = s(.link)
            app = s(.app)
        }

        init(imdbId: String, name: String, series: Bool, season: Int = 1, episode: Int = 1, poster: String? = nil,
             year: String? = nil, saved: Bool = false, inHistory: Bool = true, plays: Int = 0, lastUsed: Int64 = nowMillis(),
             link: String? = nil, app: String? = nil) {
            self.imdbId = imdbId; self.name = name; self.series = series; self.season = season; self.episode = episode
            self.poster = poster; self.year = year; self.saved = saved; self.inHistory = inHistory; self.plays = plays
            self.lastUsed = lastUsed; self.link = link; self.app = app
        }
    }

    private static let max = 300
    private let file: URL
    private(set) var entries: [Entry]

    init(file: URL = appFile("library.json")) {
        self.file = file
        let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        entries = loaded.sorted { $0.lastUsed > $1.lastUsed }
    }

    /** A title used: shared, pasted or looked up (`played` false), or opened on the TV (true). */
    func use(_ t: Title, meta: Meta.Found?, played: Bool) {
        let old = find(t.imdbId)
        var e = old ?? Entry(imdbId: t.imdbId, name: t.name, series: t.series)
        e.name = t.name.trimmed.isEmpty ? (old?.name ?? "") : t.name
        e.series = t.series
        e.season = t.series ? t.season : 1
        e.episode = t.series ? t.episode : 1
        e.poster = meta?.poster ?? old?.poster
        e.year = meta?.year ?? old?.year
        e.inHistory = true
        e.plays = (old?.plays ?? 0) + (played ? 1 : 0)
        put(e)
    }

    /** A link used: shared or pasted (`played` false), or opened on the TV (true). Keyed by the link. */
    func useLink(_ link: String, page: Links.Page, app: String?, played: Bool) {
        let old = find(link)
        var e = old ?? Entry(imdbId: link, name: page.title, series: false, link: link)
        e.name = page.title.trimmed.isEmpty ? (old?.name ?? "") : page.title
        e.poster = page.image ?? old?.poster
        e.app = app ?? old?.app
        e.inHistory = true
        e.plays = (old?.plays ?? 0) + (played ? 1 : 0)
        put(e)
    }

    /** A link saved for later, or not. */
    func setLinkSaved(_ link: String, page: Links.Page?, app: String?, saved: Bool) {
        let old = find(link)
        var e = old ?? Entry(imdbId: link, name: page?.title ?? Links.site(link), series: false, poster: page?.image,
                             inHistory: false, link: link, app: app)
        e.saved = saved
        put(e, keepTime: old != nil)
    }

    /** Saved for later, or not; a title not in the library yet comes in saved (not in history). */
    func setSaved(_ t: Title, meta: Meta.Found?, saved: Bool) {
        let old = find(t.imdbId)
        var e = old ?? Entry(imdbId: t.imdbId, name: t.name, series: t.series, poster: meta?.poster, year: meta?.year, inHistory: false)
        e.saved = saved
        put(e, keepTime: old != nil)
    }

    /** Changed by hand (name, type, season, episode). */
    func edit(_ e: Entry) { put(e, keepTime: true) }

    /** Out of history; still in Saved when saved (and gone when not). */
    func removeFromHistory(_ imdbId: String) {
        guard var old = find(imdbId) else { return }
        if old.saved {
            old.inHistory = false
            put(old, keepTime: true)
        } else {
            entries.removeAll { $0.imdbId == imdbId }
            save()
        }
    }

    /** Back as it was (Undo). */
    func restore(_ e: Entry) { put(e, keepTime: true) }

    func find(_ imdbId: String) -> Entry? { entries.first { $0.imdbId == imdbId } }

    private func put(_ entry: Entry, keepTime: Bool = false) {
        var e = entry
        if !keepTime { e.lastUsed = nowMillis() }
        entries = Array(([e] + entries.filter { $0.imdbId != e.imdbId })
            .filter { $0.inHistory || $0.saved }
            .sorted { $0.lastUsed > $1.lastUsed }
            .prefix(Library.max))
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)    // a temporary file, then renamed: never half a file
    }
}
