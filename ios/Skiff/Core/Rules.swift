import Foundation

/**
 * How links open on the TV, as data (rules.json, the same file the Android app ships: see RULES.md). The newest valid
 * copy wins: the one in the app, or the repo's (fetched at most once a day, kept only if it parses and its version is
 * higher). Rules are data, never commands: a rule can only change the link and choose among the apps the TV itself
 * says open it; flags come from a fixed list; and every value is quoted for the TV's shell. (Rules.kt)
 */
final class Rules: @unchecked Sendable {
    static let shared = Rules()

    struct Rule {
        let id: String
        let name: String?
        let hosts: [String]
        let schemes: [String]
        let rewriteFrom: Re?
        let rewriteTo: String?
        let packages: [String]
        let flags: Int
        let title: String?     // "slug", "og", "oembed:<url with {link}>"; nil: og, then the slug

        func matches(_ link: String) -> Bool {
            guard let u = URLComponents(string: link) else { return false }
            let scheme = u.scheme?.lowercased()
            let host = u.host?.lowercased().removingPrefix("www.")
            if let scheme, schemes.contains(scheme) { return true }
            guard let host, scheme == "http" || scheme == "https" else { return false }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }

        /** The link as the TV app wants it; unchanged when the result isn't a link. */
        func forTv(_ link: String) -> String {
            guard let from = rewriteFrom else { return link }
            let out = from.replaceFirst(link, rewriteTo ?? "")
            return Links.isLink(out) ? out : link
        }
    }

    private struct RuleSet {
        let version: Int
        let rules: [Rule]
        let apps: [String: String]
    }

    /** The repo's copy (raw), checked at most once a day. */
    private static let remote = "https://raw.githubusercontent.com/yogeshpaliyal/skiff/main/app/src/main/assets/rules.json"
    private static let day: TimeInterval = 24 * 60 * 60

    /** Start flags a rule may ask for, by name (Intent.FLAG_ACTIVITY_*). */
    private static let flagValues: [String: Int] = [
        "NEW_TASK": 0x1000_0000,
        "CLEAR_TASK": 0x0000_8000,
        "CLEAR_TOP": 0x0400_0000,
        "SINGLE_TOP": 0x2000_0000,
        "NO_HISTORY": 0x4000_0000,
        "RESET_TASK_IF_NEEDED": 0x0020_0000,
    ]
    /** NEW_TASK | CLEAR_TASK: a fresh start of the app's screen, so it reads the link. */
    static let defaultFlags = 0x1000_8000

    private let lock = NSLock()
    private var current: RuleSet
    private let cache = appFile("rules.json")

    private init() {
        let bundled = Bundle.main.url(forResource: "rules", withExtension: "json")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(Rules.parse)
        let downloaded = (try? String(contentsOf: cache, encoding: .utf8)).flatMap(Rules.parse)
        current = [bundled, downloaded].compactMap { $0 }.max { $0.version < $1.version }
            ?? RuleSet(version: 0, rules: [], apps: [:])
    }

    var version: Int { lock.withLock { current.version } }

    /** The repo's rules, at most once a day; kept when they parse and are newer. */
    func refresh() async {
        let stamp = "rules.checked"
        let last = UserDefaults.standard.double(forKey: stamp)
        if Date().timeIntervalSince1970 - last < Rules.day { return }
        guard let text = try? await Http.get(Rules.remote, limit: 1_000_000, browser: false) else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: stamp)
        guard let fresh = Rules.parse(text), fresh.version > version else { return }
        try? text.write(to: cache, atomically: true, encoding: .utf8)
        lock.withLock { current = fresh }
    }

    /** The first rule for this link, or nil. */
    func ruleFor(_ link: String) -> Rule? { lock.withLock { current.rules.first { $0.matches(link) } } }

    /** The link as its TV app wants it (a rule's rewrite), or as it is. */
    func forTv(_ link: String) -> String { ruleFor(link)?.forTv(link) ?? link }

    /** Start flags for this link: the rule's, or a fresh start. */
    func flags(_ link: String) -> Int { ruleFor(link)?.flags ?? Rules.defaultFlags }

    /** An app's name ("JioHotstar"): the rules' list, or the package. */
    func appName(_ pkg: String) -> String { lock.withLock { current.apps[pkg] } ?? pkg }

    /** Apps in the rule's order first (its preferred app on top), then the rest as the TV listed them. */
    func preferred<T>(_ link: String, _ apps: [T], pkg: (T) -> String) -> [T] {
        let order = ruleFor(link)?.packages ?? []
        if order.isEmpty { return apps }
        func rank(_ a: T) -> Int { order.firstIndex(of: pkg(a)) ?? order.count }
        // Stable: equal ranks keep the TV's order.
        return apps.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    private static func parse(_ text: String) -> RuleSet? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let version = (o["version"] as? NSNumber)?.intValue else { return nil }
        let rules = (o["rules"] as? [[String: Any]] ?? []).compactMap(rule)
        let apps = (o["apps"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        return RuleSet(version: version, rules: rules, apps: apps)
    }

    /** One rule, or nil when it doesn't make sense (it's skipped, the others still count). */
    private static func rule(_ o: [String: Any]) -> Rule? {
        guard let id = o["id"] as? String, let match = o["match"] as? [String: Any] else { return nil }
        func strings(_ name: String, _ from: [String: Any]) -> [String] { (from[name] as? [String] ?? []).map { $0.lowercased() } }
        let rewrite = o["rewrite"] as? [String: Any]
        var flags = defaultFlags
        if let names = o["flags"] as? [String] {
            flags = 0
            for n in names {
                guard let f = flagValues[n] else { return nil }    // an unknown flag: the rule is skipped
                flags |= f
            }
        }
        if flags & 0x1000_0000 == 0 { flags |= 0x1000_0000 }    // started from the shell: always a task
        var from: Re? = nil
        if let pattern = rewrite?["from"] as? String {
            guard let re = Re.compile(pattern, ignoreCase: true) else { return nil }
            from = re
        }
        let r = Rule(
            id: id,
            name: (o["name"] as? String)?.nonBlank,
            hosts: strings("hosts", match).map { $0.removingPrefix("www.") },
            schemes: strings("schemes", match),
            rewriteFrom: from,
            rewriteTo: rewrite?["to"] as? String,
            packages: o["packages"] as? [String] ?? [],
            flags: flags,
            title: (o["title"] as? String)?.nonBlank
        )
        return r.hosts.isEmpty && r.schemes.isEmpty ? nil : r
    }
}
