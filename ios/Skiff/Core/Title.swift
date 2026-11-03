import Foundation

/** What to open in Nuvio on the TV: a movie, or one episode of a series. (Title.kt) */
struct Title: Equatable, Hashable {
    var imdbId: String
    var name: String
    var series: Bool
    var season: Int = 1
    var episode: Int = 1

    /** Nuvio's own id for the video: "tt0120737" for a movie, "tt42127457:1:4" for an episode. */
    var videoId: String { series ? "\(imdbId):\(season):\(episode)" : imdbId }

    /** Stremio's link for it: `streams`, its stream list; else the title's page. */
    func stremioLink(streams: Bool) -> String {
        "stremio:///detail/\(series ? "series" : "movie")/\(imdbId)" + (streams ? "/\(videoId)" : "")
    }

    /** Nuvio's own link: the title's page (over pairing). */
    var nuvioLink: String { "nuvio://\(series ? "series" : "movie")/\(imdbId)" }

    /**
     * A shared page: its IMDb id, and whatever its text says about the name and type (nil = not said). Or, with no
     * IMDb id, any other `link` (JioHotstar, YouTube…), with imdbId empty.
     */
    struct Shared: Equatable {
        var imdbId: String
        var name: String
        var series: Bool?
        var link: String? = nil
    }

    private static let imdbIdRe = Re(#"\btt\d{5,}\b"#)

    static func isImdbId(_ s: String) -> Bool { imdbIdRe.matches(s.trimmed) }

    /** The IMDb id in any text: "tt0120737", "https://m.imdb.com/title/tt0120737/?ref_=…". */
    static func idIn(_ text: String) -> String? { imdbIdRe.find(text)?[0] }

    /**
     * What a share brings. Safari shares the page's URL (and its title as the subject); the IMDb app puts both in the
     * text ("Agent Kim Reactivated (TV Series 2025– ) ⭐ 7.6 | Action https://m.imdb.com/title/tt42127457/"). With no
     * IMDb id, any other link in it; nil when there's neither.
     */
    static func fromShared(text: String?, subject: String?) -> Shared? {
        let parts = [subject, text].compactMap { $0 }
        let all = parts.joined(separator: "\n")
        let link = Links.linkIn(all)
        let firstSubjectLine = subject?.components(separatedBy: .newlines).first { !$0.trimmed.isEmpty }?.trimmed ?? ""
        let shared = { (l: String) in Shared(imdbId: "", name: firstSubjectLine, series: nil, link: l) }
        // Another site's title page (TitleSources), even one with the IMDb id in it (MDBList's): looked up.
        if let link, TitleSources.of(link) != nil { return shared(link) }
        guard let id = idIn(all) else { return link.map(shared) }
        let name = parts
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmed }
            .first { !$0.isEmpty && !$0.hasPrefix("http") && idIn($0) == nil }
            .map(cleanName) ?? ""
        // The IMDb app says "TV Series"; a browser's page title doesn't say (Cinemeta will).
        let series: Bool? = Re("TV (Mini )?Series", ignoreCase: true).containsMatch(all) ? true : nil
        return Shared(imdbId: id, name: name, series: series)
    }

    /** "The Lord of the Rings… (2001) - IMDb" → "The Lord of the Rings…". */
    private static func cleanName(_ line: String) -> String {
        line.before("http").before(" - IMDb").before(" | ").before(" (").before(" ⭐")
            .trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }
}
