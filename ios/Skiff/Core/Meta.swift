import Foundation

/**
 * Titles found by name (search), and a title's name and type from its IMDb id, through Cinemeta (the free catalog
 * Stremio and Nuvio use; no key). An id is either a movie or a series: both are asked at once, and the one that
 * answers wins. (Meta.kt)
 */
enum Meta {
    struct Found: Equatable {
        var name: String
        var series: Bool
        var poster: String? = nil
        var background: String? = nil
        var year: String? = nil       // "2001", "2025–"
        var genres: [String] = []
        var rating: String? = nil     // IMDb, "8.9"
        var runtime: String? = nil    // "179 min"
    }

    /** A search result: an IMDb title, enough to show it and fill it in. */
    struct Hit: Equatable, Identifiable {
        var imdbId: String
        var name: String
        var series: Bool
        var year: String?
        var poster: String?
        var id: String { imdbId }
    }

    private static let cinemeta = "https://v3-cinemeta.strem.io/meta"
    private static let catalogUrl = "https://v3-cinemeta.strem.io/catalog"

    private static let spaces = Re(#"[\s\p{Z}]+"#)
    private static let invisible = Re(#"[​-‍⁠﻿]"#)

    /**
     * The words typed, as Cinemeta should get them: every run of spaces of any kind one plain space, and the
     * invisible characters some keyboards add removed.
     */
    static func words(_ query: String) -> String {
        spaces.split(invisible.replaceAll(query, "")).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /** The catalog address for a search: the words percent-encoded, a space as %20 (a "+" is a plus in a path). */
    static func searchUrl(_ type: String, _ query: String) -> String {
        "\(catalogUrl)/\(type)/top/search=\(words(query).formEncoded.replacingOccurrences(of: "+", with: "%20")).json"
    }

    /**
     * Titles whose name matches `query`, movies and series asked at once and taken in turn (the best of each first),
     * up to `limit`. When several words find nothing, the last ones are let go of, one at a time and at most two.
     * Empty on no match or no internet. Throws when cancelled.
     */
    static func search(_ query: String, limit: Int = .max) async throws -> [Hit] {
        let all = words(query).split(separator: " ").map(String.init)
        if all.isEmpty { return [] }
        var n = all.count
        while n >= max(1, all.count - 2) {
            let q = all.prefix(n).joined(separator: " ")
            if n < all.count && q.count < 3 { break }     // one short word left: too broad
            let hits = try await searchOnce(q, limit: limit)
            if !hits.isEmpty { return hits }
            n -= 1
        }
        return []
    }

    private static func searchOnce(_ query: String, limit: Int) async throws -> [Hit] {
        async let movies = catalog("movie", query)
        async let series = catalog("series", query)
        let m = try await movies
        let s = try await series
        var out: [Hit] = []
        var seen = Set<String>()
        for i in 0..<max(m.count, s.count) {
            for h in [i < m.count ? m[i] : nil, i < s.count ? s[i] : nil].compactMap({ $0 }) where seen.insert(h.imdbId).inserted {
                out.append(h)
            }
        }
        return Array(out.prefix(limit))
    }

    private static func catalog(_ type: String, _ query: String) async throws -> [Hit] {
        guard let o = try await Http.json(searchUrl(type, query)), let metas = o["metas"] as? [[String: Any]] else {
            try Task.checkCancellation()
            return []
        }
        try Task.checkCancellation()    // typed on meanwhile: not these
        return metas.compactMap { m in
            let id = jsonString(m, "id"), name = jsonString(m, "name")
            guard Title.isImdbId(id), !name.trimmed.isEmpty else { return nil }
            let year = jsonString(m, "releaseInfo")
            let poster = jsonString(m, "poster")
            return Hit(imdbId: id, name: name, series: type == "series",
                       year: year.trimmed.isEmpty || year == "null" ? nil : year,
                       poster: poster.hasPrefix("http") ? poster : nil)
        }
    }

    /** nil when neither knows it (or there's no internet). */
    static func lookup(_ imdbId: String) async throws -> Found? {
        async let movie = fetch("movie", imdbId)
        async let series = fetch("series", imdbId)
        if let m = try await movie { return found(m, series: false) }
        if let s = try await series { return found(s, series: true) }
        return nil
    }

    private static func found(_ m: [String: Any], series: Bool) -> Found {
        func http(_ k: String) -> String? { let v = jsonString(m, k); return v.hasPrefix("http") ? v : nil }
        return Found(
            name: jsonString(m, "name"),
            series: series,
            poster: http("poster"),
            background: http("background"),
            year: jsonString(m, "releaseInfo").nonBlank,
            genres: Array((m["genres"] as? [Any] ?? []).map { "\($0)" }.prefix(3)),
            rating: jsonString(m, "imdbRating").nonBlank,
            runtime: jsonString(m, "runtime").nonBlank
        )
    }

    /** The title's "meta" object, when this type knows the id (the wrong type redirects: not followed). */
    private static func fetch(_ type: String, _ id: String) async throws -> [String: Any]? {
        guard let o = try await Http.json("\(cinemeta)/\(type)/\(id).json", redirects: false),
              let meta = o["meta"] as? [String: Any], !jsonString(meta, "name").trimmed.isEmpty else { return nil }
        return meta
    }
}
