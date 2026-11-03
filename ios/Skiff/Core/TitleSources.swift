import Foundation

/**
 * A site whose links are titles but don't carry the IMDb id (Trakt…): looked up, then opened in Nuvio or Stremio like
 * a shared IMDb page. A new site is a `TitleSource` and a line in `TitleSources.all`. (TitleSource.kt and one file per
 * site in the Android app.)
 */
protocol TitleSource {
    /** Its name, as the app says it ("Trakt"). */
    var name: String { get }
    /** A short key: "trakt". */
    var key: String { get }
    /** Whether `link` is one of its title pages. */
    func handles(_ link: String) -> Bool
    /** The title `link` points at, or nil when it can't be found (no internet, no IMDb id). */
    func resolve(_ link: String) async throws -> TitleFound?
    /** Not found: what to search Cinemeta for instead (the name in the link), or nil. */
    func searchFor(_ link: String) -> String?
}

/** `episodeKnown`: the link named the episode, so it plays without asking for one. */
struct TitleFound: Equatable {
    var title: Title
    var episodeKnown = false
}

enum TitleSources {
    static let all: [TitleSource] = [Trakt(), Simkl(), Letterboxd(), MdbList(), Wetrakr()]

    /** The site `link` is a title page of; nil for IMDb's (read directly) and any other link. */
    static func of(_ link: String) -> TitleSource? { all.first { $0.handles(link.trimmed) } }

    private static let imdbLink = Re(#"imdb\.com/title/(tt\d{5,})"#)
    private static let yearRe = Re(#"-((?:19|20)\d\d)$"#)

    /** The IMDb id a title's page links to. */
    static func imdbLinkIn(_ html: String) -> String? { imdbLink.group(html) }

    /** "the-lord-of-the-rings-2001" → ("the lord of the rings", "2001"). */
    static func nameAndYear(_ slug: String) -> (name: String, year: String?) {
        let year = yearRe.group(slug)
        let base = year.map { slug.removingSuffix("-" + $0) } ?? slug
        return (base.replacingOccurrences(of: "-", with: " ").trimmed, year)
    }

    /** A page's text, or nil when it doesn't answer. */
    static func page(_ url: String, limit: Int = 600_000) async throws -> String? {
        try await Http.get(url, limit: limit)
    }

    /** A slug's words searched in Cinemeta: the first of the right type (and year, when the slug has one). */
    static func byName(_ slug: String, series: Bool) async throws -> String? {
        if slug.allSatisfy(\.isNumber) { return nil }
        let (name, year) = nameAndYear(slug)
        let hits = try await Meta.search(name, limit: 20).filter { $0.series == series }
        return (hits.first { h in year.map { y in h.year?.hasPrefix(y) ?? false } ?? false } ?? hits.first)?.imdbId
    }
}

private func int(_ s: String) -> Int? { Int(s) }

/** Trakt pages (trakt.tv, app.trakt.tv): a movie, a show, or one episode of it. */
struct Trakt: TitleSource {
    let name = "Trakt"
    let key = "trakt"

    struct Ref: Equatable { var slug: String; var series: Bool; var season: Int? = nil; var episode: Int? = nil }

    private static let link = Re(
        #"^https?://(?:[a-z0-9-]+\.)?trakt\.tv/(movies|shows)/([^/?#\s]+)(?:/seasons/(\d+)(?:/episodes/(\d+))?)?"#, ignoreCase: true)

    static func parse(_ link: String) -> Ref? {
        guard let g = Trakt.link.find(link.trimmed) else { return nil }
        let series = g[1].lowercased() == "shows"
        return Ref(slug: g[2], series: series, season: series ? int(g[3]) : nil, episode: series ? int(g[4]) : nil)
    }

    func handles(_ link: String) -> Bool { Trakt.parse(link) != nil }

    func resolve(_ link: String) async throws -> TitleFound? {
        guard let ref = Trakt.parse(link) else { return nil }
        // The title's own page (an episode's links to the episode on IMDb; Nuvio wants the show's).
        let page = "https://trakt.tv/\(ref.series ? "shows" : "movies")/\(ref.slug)"
        var id = try await TitleSources.page(page).flatMap(TitleSources.imdbLinkIn)
        if id == nil { id = try await TitleSources.byName(ref.slug, series: ref.series) }
        guard let id else { return nil }
        return TitleFound(title: Title(imdbId: id, name: "", series: ref.series, season: ref.season ?? 1, episode: ref.episode ?? 1),
                          episodeKnown: ref.episode != nil)
    }

    func searchFor(_ link: String) -> String? { Trakt.parse(link).map { TitleSources.nameAndYear($0.slug).name } }
}

/** Simkl pages (simkl.com): a movie, a TV show or an anime, and an episode of a show. */
struct Simkl: TitleSource {
    let name = "Simkl"
    let key = "simkl"

    struct Ref: Equatable { var type: String; var id: String; var slug: String?; var season: Int? = nil; var episode: Int? = nil }

    private static let link = Re(
        #"^https?://(?:www\.)?simkl\.com/(movies|tv|anime)/(\d+)(?:/([^/?#\s]+))?(?:/season-(\d+)(?:/episode-(\d+))?)?"#, ignoreCase: true)
    private static let imdb = Re(#""imdb"\s*:\s*"(tt\d{5,})""#)
    private static let animeType = Re(#""anime_type"\s*:\s*"([^"]*)""#)

    static func parse(_ link: String) -> Ref? {
        guard let g = Simkl.link.find(link.trimmed) else { return nil }
        let t = g[1].lowercased()
        let series = t != "movies"
        return Ref(type: t, id: g[2], slug: g[3].isEmpty ? nil : g[3], season: series ? int(g[4]) : nil, episode: series ? int(g[5]) : nil)
    }

    func handles(_ link: String) -> Bool { Simkl.parse(link) != nil }

    /** From the API's answer for the title: its IMDb id, and whether it's a series (`type` from the link). */
    static func read(_ json: String, type: String) -> (String, Bool)? {
        guard let id = imdb.group(json) else { return nil }
        let series: Bool
        switch type {
        case "movies": series = false
        case "anime": series = animeType.find(json).map { $0[1] } != "movie"
        default: series = true
        }
        return (id, series)
    }

    func resolve(_ link: String) async throws -> TitleFound? {
        guard let ref = Simkl.parse(link) else { return nil }
        let byType = ref.type != "movies"     // an anime movie is only told by the API
        var found = try await TitleSources.page("https://api.simkl.com/\(ref.type)/\(ref.id)").flatMap { Simkl.read($0, type: ref.type) }
        if found == nil, let slug = ref.slug, let id = try await TitleSources.byName(slug, series: byType) { found = (id, byType) }
        guard let f = found else { return nil }
        let (id, series) = f
        return TitleFound(title: Title(imdbId: id, name: "", series: series, season: ref.season ?? 1, episode: ref.episode ?? 1),
                          episodeKnown: series && ref.episode != nil)
    }

    func searchFor(_ link: String) -> String? { Simkl.parse(link)?.slug.map { TitleSources.nameAndYear($0).name } }
}

/** Letterboxd films (letterboxd.com/film/…, a member's review of one, and boxd.it short links): always movies. */
struct Letterboxd: TitleSource {
    let name = "Letterboxd"
    let key = "letterboxd"

    private static let film = Re(#"^https?://(?:www\.)?letterboxd\.com/(?:[^/?#\s]+/)?film/([^/?#\s]+)"#, ignoreCase: true)
    private static let short = Re(#"^https?://boxd\.it/[A-Za-z0-9]+"#, ignoreCase: true)

    static func slug(_ link: String) -> String? { film.group(link.trimmed) }

    func handles(_ link: String) -> Bool { Letterboxd.slug(link) != nil || Letterboxd.short.containsMatch(link.trimmed) }

    func resolve(_ link: String) async throws -> TitleFound? {
        let slug = Letterboxd.slug(link)
        guard let page = slug.map({ "https://letterboxd.com/film/\($0)/" }) ?? Letterboxd.short.find(link.trimmed)?[0] else { return nil }
        var id = try await TitleSources.page(page).flatMap(TitleSources.imdbLinkIn)
        if id == nil, let slug { id = try await TitleSources.byName(slug, series: false) }
        guard let id else { return nil }
        return TitleFound(title: Title(imdbId: id, name: "", series: false))
    }

    func searchFor(_ link: String) -> String? { Letterboxd.slug(link).map { TitleSources.nameAndYear($0).name } }
}

/** MDBList pages: mdblist.com/movie/tt…, /show/tt…, or /show/3xzbl-carrie (MDBList's own id and the name). */
struct MdbList: TitleSource {
    let name = "MDBList"
    let key = "mdblist"

    struct Ref: Equatable { var series: Bool; var imdbId: String? = nil; var slug: String? = nil }

    private static let link = Re(#"^https?://(?:www\.)?mdblist\.com/(movie|show)/(?:(tt\d{5,})|[a-z0-9]{5}-([^/?#\s]+))"#, ignoreCase: true)

    static func parse(_ link: String) -> Ref? {
        guard let g = MdbList.link.find(link.trimmed) else { return nil }
        return Ref(series: g[1].lowercased() == "show", imdbId: g[2].isEmpty ? nil : g[2], slug: g[3].isEmpty ? nil : g[3])
    }

    func handles(_ link: String) -> Bool { MdbList.parse(link) != nil }

    func resolve(_ link: String) async throws -> TitleFound? {
        guard let ref = MdbList.parse(link) else { return nil }
        var id = ref.imdbId
        if id == nil, let slug = ref.slug { id = try await TitleSources.byName(slug, series: ref.series) }
        guard let id else { return nil }
        return TitleFound(title: Title(imdbId: id, name: "", series: ref.series))
    }

    func searchFor(_ link: String) -> String? { MdbList.parse(link)?.slug.map { TitleSources.nameAndYear($0).name } }
}

/** WeTrakr pages (wetrakr.com): a movie, a show, or one episode of it. */
struct Wetrakr: TitleSource {
    let name = "WeTrakr"
    let key = "wetrakr"

    struct Ref: Equatable { var id: String; var series: Bool; var season: Int? = nil; var episode: Int? = nil }

    private static let link = Re(#"^https?://(?:www\.)?wetrakr\.com/(movies|shows)/(\d+)(?:/seasons/(\d+)(?:/episodes/(\d+))?)?"#, ignoreCase: true)
    private static let imdb = Re(#""imdb"\s*:\s*\{\s*"id"\s*:\s*"(tt\d{5,})""#)

    static func parse(_ link: String) -> Ref? {
        guard let g = Wetrakr.link.find(link.trimmed) else { return nil }
        let series = g[1].lowercased() == "shows"
        return Ref(id: g[2], series: series, season: series ? int(g[3]) : nil, episode: series ? int(g[4]) : nil)
    }

    func handles(_ link: String) -> Bool { Wetrakr.parse(link) != nil }

    static func imdbIdIn(_ json: String) -> String? { imdb.group(json) }

    func resolve(_ link: String) async throws -> TitleFound? {
        guard let ref = Wetrakr.parse(link) else { return nil }
        let data = "https://wetrakr.com/proxy/frontend/\(ref.series ? "shows" : "movies")/\(ref.id)"
        guard let id = try await TitleSources.page(data).flatMap(Wetrakr.imdbIdIn) else { return nil }
        return TitleFound(title: Title(imdbId: id, name: "", series: ref.series, season: ref.season ?? 1, episode: ref.episode ?? 1),
                          episodeKnown: ref.episode != nil)
    }

    func searchFor(_ link: String) -> String? { nil }
}
