import Foundation

// Small helpers that make the port from Kotlin read like the original: regexes with Kotlin's semantics (a group that
// didn't take part is ""), and substringBefore / substringAfter.

/** A regular expression (ICU, like Java's): `find`, `matches` (the whole string), `containsMatch`. */
struct Re {
    let ns: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false) {
        // The patterns are constants: a bad one is a programming error.
        ns = try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    /** Builds one from data (a link rule); nil when it doesn't compile. */
    static func compile(_ pattern: String, ignoreCase: Bool = false) -> Re? {
        guard let ns = try? NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : []) else { return nil }
        return Re(ns: ns)
    }

    private init(ns: NSRegularExpression) { self.ns = ns }

    /** The first match: [whole, group1, …], a group that didn't take part as "". */
    func find(_ s: String) -> [String]? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = ns.firstMatch(in: s, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let rr = Range(r, in: s) else { return "" }
            return String(s[rr])
        }
    }

    /** Group 1 of the first match. */
    func group(_ s: String, _ n: Int = 1) -> String? {
        guard let g = find(s), g.count > n, !g[n].isEmpty else { return nil }
        return g[n]
    }

    func containsMatch(_ s: String) -> Bool { find(s) != nil }

    /** The whole string matches. */
    func matches(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = ns.firstMatch(in: s, options: [.anchored], range: range) else { return false }
        return m.range.location == 0 && m.range.length == range.length
    }

    /** Every match's whole text. */
    func all(_ s: String) -> [String] {
        let range = NSRange(s.startIndex..., in: s)
        return ns.matches(in: s, range: range).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /** The first match replaced by `template` ($1 works), like Kotlin's replaceFirst. */
    func replaceFirst(_ s: String, _ template: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = ns.firstMatch(in: s, range: range), let r = Range(m.range, in: s) else { return s }
        let replacement = ns.replacementString(for: m, in: s, offset: 0, template: template)
        return s.replacingCharacters(in: r, with: replacement)
    }

    /** Splits around the matches. */
    func split(_ s: String) -> [String] {
        let range = NSRange(s.startIndex..., in: s)
        var out: [String] = []
        var start = s.startIndex
        for m in ns.matches(in: s, range: range) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[start..<r.lowerBound]))
            start = r.upperBound
        }
        out.append(String(s[start...]))
        return out
    }

    func replaceAll(_ s: String, _ with: String) -> String {
        ns.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: with))
    }
}

extension String {
    func before(_ delimiter: String) -> String {
        guard let r = range(of: delimiter) else { return self }
        return String(self[..<r.lowerBound])
    }

    func after(_ delimiter: String, missing: String? = nil) -> String {
        guard let r = range(of: delimiter) else { return missing ?? self }
        return String(self[r.upperBound...])
    }

    func removingPrefix(_ p: String) -> String { hasPrefix(p) ? String(dropFirst(p.count)) : self }
    func removingSuffix(_ s: String) -> String { hasSuffix(s) ? String(dropLast(s.count)) : self }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonBlank: String? { trimmed.isEmpty ? nil : self }

    /** Java's URLEncoder.encode(s, "UTF-8"): everything but A–Z a–z 0–9 . - * _ escaped, a space as "+". */
    var formEncoded: String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-*_ ")
        return (addingPercentEncoding(withAllowedCharacters: safe) ?? self).replacingOccurrences(of: " ", with: "+")
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

/** A JSON object's field as a string, as org.json's optString gives it (numbers too); "" when missing or null. */
func jsonString(_ o: [String: Any], _ key: String) -> String {
    switch o[key] {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    default: return ""
    }
}

/** Milliseconds since 1970, as Android's System.currentTimeMillis(): what the stored files use. */
func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/** Where Skiff keeps its files: Application Support (made when missing). */
func appFile(_ name: String) -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}
