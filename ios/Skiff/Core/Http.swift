import Foundation

/** HTTP GETs, the way the Android app makes them: short timeouts, a phone browser's User-Agent for web pages. */
enum Http {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 20
        return URLSession(configuration: c)
    }()

    static let browserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /** Stops at a redirect: Cinemeta redirects (307) an id asked as the wrong type. */
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /**
     * A page's text (up to `limit` bytes), or nil when it doesn't answer 2xx (or there's no internet). Throws only
     * when the task was cancelled (typed on meanwhile).
     */
    static func get(_ url: String, limit: Int = 200_000, browser: Bool = true, redirects: Bool = true) async throws -> String? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        if browser { req.setValue(browserAgent, forHTTPHeaderField: "User-Agent") }
        do {
            let (data, response) = redirects
                ? try await session.data(for: req)
                : try await session.data(for: req, delegate: NoRedirect())
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            let bytes = data.count > limit ? data.prefix(limit) : data
            return String(decoding: bytes, as: UTF8.self)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    /** The JSON object at `url`, or nil. */
    static func json(_ url: String, redirects: Bool = true) async throws -> [String: Any]? {
        guard let text = try await get(url, limit: 5_000_000, browser: false, redirects: redirects) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
