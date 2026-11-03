import Foundation

/**
 * Any other link (JioHotstar, YouTube, Netflix…): sent to the TV, to whichever TV app opens it. Some apps open their
 * website's links badly on TV; those are turned into the app's own link first (Rules). (Links.kt)
 */
enum Links {
    struct Page: Equatable {
        var title: String
        var image: String? = nil
        var by: String? = nil
    }

    private static let urlInText = Re(#"(https?://\S+|[a-z][a-z0-9+.-]*://\S+)"#, ignoreCase: true)

    /** The first link in shared text. */
    static func linkIn(_ text: String) -> String? {
        guard let found = urlInText.find(text)?[0] else { return nil }
        var s = found
        while let last = s.last, ".,)\"'".contains(last) { s.removeLast() }
        return s
    }

    static func isLink(_ s: String) -> Bool { urlInText.matches(s.trimmed) }

    /** The link the TV app wants: its rule's rewrite (JioHotstar: www.hotstar.com/in/… → hotstar://in/…), or as it is. */
    static func forTv(_ link: String) -> String { Rules.shared.forTv(link) }

    /** "hotstar.com", or the scheme of an app link ("hotstar"). */
    static func site(_ link: String) -> String {
        guard let u = URLComponents(string: link) else { return link }
        let s = u.host ?? u.scheme ?? ""
        return s.removingPrefix("www.").removingPrefix("m.")
    }

    /** The TV app's name for its package (the rules' list); others by package. */
    static func appName(_ pkg: String) -> String { Rules.shared.appName(pkg) }

    /**
     * A name (and picture) for the link, from where its rule says: "oembed:<url>" (YouTube), "og" (the page's Open
     * Graph tags, when they name this page), or "slug" (the title in the link itself). No rule: the page's tags, then
     * the slug. Else `fallback` (the shared page's title), else the site.
     */
    static func page(_ link: String, fallback: String?) async -> Page {
        let how = Rules.shared.ruleFor(link)?.title
        var fromWeb: Page? = nil
        if let how, how.hasPrefix("oembed:") {
            fromWeb = await oembed(String(how.dropFirst("oembed:".count)), link)
        } else if how == "slug" {
            fromWeb = nil
        } else if link.hasPrefix("http") {
            fromWeb = await openGraph(link)
        }
        if let p = fromWeb, !p.title.trimmed.isEmpty { return p }
        if let s = fromSlug(link) { return Page(title: s) }
        return Page(title: fallback?.nonBlank ?? site(link))
    }

    /** An oEmbed endpoint ("https://www.youtube.com/oembed?format=json&url={link}"), https only. */
    private static func oembed(_ endpoint: String, _ link: String) async -> Page? {
        let url = endpoint.replacingOccurrences(of: "{link}", with: link.formEncoded)
        guard url.hasPrefix("https://"), let o = try? await Http.json(url) else { return nil }
        let thumb = jsonString(o, "thumbnail_url")
        return Page(title: jsonString(o, "title"), image: thumb.hasPrefix("http") ? thumb : nil, by: jsonString(o, "author_name").nonBlank)
    }

    private static func openGraph(_ link: String) async -> Page? {
        guard let html = try? await Http.get(link, limit: 400_000) else { return nil }
        func meta(_ p: String) -> String? {
            Re(#"<meta[^>]+(?:property|name)=["']"# + p + #"["'][^>]*content=["']([^"']+)"#, ignoreCase: true).group(html).map(unescape)
        }
        guard let title = meta("og:title") else { return nil }
        let siteName = meta("og:site_name")
        // A site-wide title ("JioHotstar - Watch TV Shows, Movies…") doesn't name the page.
        let generic = (siteName.map { title.hasPrefix($0) } ?? false) || title.contains(" - Watch ")
        if generic { return nil }
        let image = meta("og:image")
        return Page(title: title, image: (image?.hasPrefix("http") ?? false) ? image : nil, by: siteName)
    }

    /** The longest words-with-hyphens segment of the path that isn't a known section. */
    static func fromSlug(_ link: String) -> String? {
        let skip: Set<String> = ["in", "movies", "shows", "watch", "title", "detail", "video", "videos", "series", "tv", "episode"]
        let words = Re(#"[a-zA-Z]+(-[a-zA-Z0-9]+)+"#)
        let path = URLComponents(string: link)?.path ?? ""
        let segments = path.split(separator: "/").map(String.init)
            .filter { !skip.contains($0.lowercased()) && words.matches($0) }
        // The first of the longest, as Kotlin's maxByOrNull picks it.
        guard var best = segments.first else { return nil }
        for s in segments where s.count > best.count { best = s }
        return best.split(separator: "-").map { w in w.prefix(1).uppercased() + w.dropFirst() }.joined(separator: " ")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
