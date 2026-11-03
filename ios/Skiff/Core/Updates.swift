import Foundation
import Observation

/**
 * Newer versions of Skiff, from GitHub releases (where the .ipa is published), asked at most twice a day or now from
 * Settings. iOS doesn't let an app install its own update: a newer release opens its page, to get the .ipa there.
 * (Updates.kt and the github flavor's StoreUpdates.kt)
 */
@MainActor @Observable
final class Updates {
    static let shared = Updates()

    struct Release: Equatable {
        var version: String
        var notes: String
        var ipaUrl: String?
        var pageUrl: String
    }

    private static let latest = "https://api.github.com/repos/yogeshpaliyal/skiff/releases/latest"
    private static let every: TimeInterval = 12 * 60 * 60

    /** The newer release, when there's one; nil when up to date or not checked yet. */
    private(set) var update: Release?

    /** This build's version: "1.11.1". */
    nonisolated static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "").before("-")
    }

    nonisolated static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /** True when `a` is a later version than `b` ("1.10.0" > "1.9.2"). */
    nonisolated static func newer(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
            if d != 0 { return d > 0 }
        }
        return false
    }

    /** Asks GitHub (`force`, or when the last check is old). Returns the newer release, or nil when up to date. */
    @discardableResult
    func check(force: Bool = false) async throws -> Release? {
        let d = UserDefaults.standard
        let cached = d.data(forKey: "updates.latest").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let fresh = Date().timeIntervalSince1970 - d.double(forKey: "updates.checkedAt") < Updates.every
        var json = cached
        if force || !fresh || cached == nil {
            do {
                var req = URLRequest(url: URL(string: Updates.latest)!)
                req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await Http.session.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                d.set(data, forKey: "updates.latest")
                d.set(Date().timeIntervalSince1970, forKey: "updates.checkedAt")
            } catch {
                if force { throw error }
            }
        }
        let release = json.map(Updates.parse)
        update = release.flatMap { Updates.newer($0.version, Updates.current) ? $0 : nil }
        return update
    }

    private static func parse(_ o: [String: Any]) -> Release {
        let assets = o["assets"] as? [[String: Any]] ?? []
        let ipa = assets.first { jsonString($0, "name").hasSuffix(".ipa") }.map { jsonString($0, "browser_download_url") }
        return Release(
            version: jsonString(o, "tag_name").removingPrefix("v"),
            notes: jsonString(o, "body"),
            ipaUrl: ipa,
            pageUrl: jsonString(o, "html_url").nonBlank ?? "https://github.com/yogeshpaliyal/skiff/releases/latest"
        )
    }
}
