import Foundation

/**
 * A remote connection to the TV, whichever way it goes: the Google TV remote protocol (paired with a code: Atv.Remote)
 * or the TV's ADB (TvLink.Remote). Keys are Android's KeyEvent codes. (TvKeys.kt)
 */
protocol TvKeys: AnyObject {
    func key(_ code: Int) async throws
    /** Over the remote protocol with a field focused, replaces the field's text; otherwise types it in. */
    func text(_ s: String) async throws
    /** The text of the TV's focused field, as the TV tells it; nil when it doesn't (ADB, or no field focused). */
    var field: String? { get }
    /** Called (on the main actor) when `field` changes. */
    var onField: ((String?) -> Void)? { get set }
    /** Still connected, as far as the phone knows. */
    var isOpen: Bool { get }
    /** A mouse pointer on the TV: over ADB only, the remote protocol has none. */
    var hasCursor: Bool { get }
    /** Moves the TV's pointer by (dx, dy) counts, with `buttons` held and the wheel turned by `wheel`. */
    func mouse(dx: Int, dy: Int, buttons: Int, wheel: Int) async throws
    func close()
}

extension TvKeys {
    var hasCursor: Bool { false }
    func mouse(dx: Int, dy: Int, buttons: Int, wheel: Int) async throws {}
}

enum MouseButton {
    static let left = 1
    static let right = 2
}

/**
 * Talks to the TV over Wi-Fi, through its own ADB (port 5555), as `adb shell` would from a computer: which Nuvio apps
 * it has, a title opened in one (straight to the stream picker), links opened in the app picked, the remote, the
 * pointer, a shell command, an APK installed. The phone's ADB key is made once: the first time, the TV asks "Allow USB
 * debugging?" for it. (TvLink.kt)
 */
enum TvLink {
    static let port: UInt16 = 5555
    /** Between two answers in one shell call. */
    private static let split = "--8<--skiff--8<--"
    /** Nuvio's activity: forks that renamed the app (and even the scheme) usually keep the code, and this class. */
    private static let nuvioClass = "com.nuvio.tv.MainActivity"

    /** An app on the TV to open titles in: a Nuvio build, or Stremio (which takes its own links). */
    struct NuvioApp: Equatable, Identifiable {
        var pkg: String
        var component: String
        var version: String?
        var source: String
        var stremio = false
        var id: String { component }
        var name: String { stremio ? "Stremio" : pkg.hasPrefix("com.nuvio.") ? "Nuvio" : pkg }
    }

    /** A TV app that opens a link (JioHotstar, YouTube…). */
    struct LinkApp: Equatable, Identifiable {
        var pkg: String
        var component: String
        var id: String { component }
        var name: String { Links.appName(pkg) }
    }

    /** USB debugging on the TV, for this phone: allowed, on but this phone not allowed (yet), or off. */
    enum AdbState { case allowed, notAllowed, off }

    /** One connection at a time: two at once, the first time, make the TV ask twice. */
    private static let lock = AsyncMutex()

    private static func withTv<T>(_ host: String, answer: TimeInterval = 60, _ body: (Adb) async throws -> T) async throws -> T {
        try await lock.withLock {
            let tv = try await Adb.connect(host: host, port: port, answer: answer)
            defer { tv.close() }
            return try await body(tv)
        }
    }

    /** A quick look (a few seconds at most): the port shut is OFF; open but no answer to this phone's key is NOT_ALLOWED. */
    static func check(_ host: String) async -> AdbState {
        await lock.withLock {
            let probe = Socket(host: host, port: port)
            do {
                try await probe.connect(timeout: 2)
                probe.close()
            } catch {
                return .off
            }
            do {
                let tv = try await Adb.connect(host: host, port: port, answer: 4)
                defer { tv.close() }
                _ = try await tv.shell("true")
                return .allowed
            } catch {
                return .notAllowed
            }
        }
    }

    /** A shell command on the TV, as `adb shell` runs it (Settings → ADB tools). */
    static func shell(_ host: String, _ command: String) async throws -> Adb.ShellResult {
        try await withTv(host) { try await $0.shell(command) }
    }

    /** Installs an APK on the TV (up to 5 minutes for the TV to answer). */
    static func install(_ host: String, apk: URL) async throws {
        try await withTv(host, answer: 300) { try await $0.install(apk) }
    }

    /** The Nuvio apps on that TV, the TV build first, then Stremio. */
    static func apps(_ host: String) async throws -> [NuvioApp] {
        try await withTv(host) { try await detect($0) }
    }

    /**
     * What Android says opens `nuvio://` (every Nuvio build, and forks that kept it), plus what opens `stremio://` with
     * Nuvio's activity class (forks with their own scheme). The other apps opening stremio:// are Stremio itself.
     */
    private static func detect(_ tv: Adb) async throws -> [NuvioApp] {
        let query = "cmd package query-activities --brief -a android.intent.action.VIEW -d"
        let out = try await tv.shell("\(query) nuvio://open; echo '\(split)'; \(query) stremio://open").output
        let nuvio = components(out.before(split))
        let after = components(out.after(split, missing: ""))
        let forks = after.filter { $0.after("/") == nuvioClass }
        let stremio = after.filter { $0.after("/") != nuvioClass }
        var byPkg: [(String, String)] = []
        for c in nuvio + forks + stremio where !byPkg.contains(where: { $0.0 == c.before("/") }) { byPkg.append((c.before("/"), c)) }
        var apps: [NuvioApp] = []
        for (pkg, component) in byPkg {
            let info = try await tv.shell("dumpsys package \(pkg) | grep -E 'versionName=|installerPackageName='").output
            apps.append(NuvioApp(
                pkg: pkg,
                component: component,
                version: Re(#"versionName=(\S+)"#).group(info),
                source: source(Re(#"installerPackageName=(\S+)"#).group(info)),
                stremio: component.after("/") != nuvioClass && !nuvio.contains(component)
            ))
        }
        func rank(_ a: NuvioApp) -> Int { a.pkg == "com.nuvio.tv" ? 0 : a.stremio ? 2 : 1 }
        return apps.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /**
     * The remote: one connection kept open while it's showing, and the keys sent in order, one at a time. `cmd input`
     * (quicker than `input`: no Java process to start).
     */
    final class Remote: TvKeys, @unchecked Sendable {
        private let tv: Adb
        private let order = AsyncMutex()
        private let pointer = AsyncMutex()
        private var hid: Adb.Shell?

        var onField: ((String?) -> Void)?
        var field: String? { nil }
        var isOpen: Bool { tv.isOpen }
        var hasCursor: Bool { true }

        fileprivate init(tv: Adb) { self.tv = tv }

        func key(_ code: Int) async throws { try await run("cmd input keyevent \(code)") }

        /** Text into the TV's focused field (a search box): spaces as %s, as `input text` wants them. */
        func text(_ s: String) async throws { try await run("cmd input text " + TvLink.q(s.replacingOccurrences(of: " ", with: "%s"))) }

        private func run(_ command: String) async throws {
            try await order.withLock { _ = try await tv.shell(command) }
        }

        /**
         * The pointer: a USB mouse made up on the TV with Android's `hid` command (Android 9 and later), opened at the
         * first move and kept while the remote is. Its reports go to the command's input as they come.
         */
        func mouse(dx: Int, dy: Int, buttons: Int, wheel: Int) async throws {
            try await pointer.withLock {
                let m: Adb.Shell
                if let h = hid {
                    m = h
                } else {
                    m = try await tv.openShell("hid -")
                    try await m.write(#"{"id":1,"command":"register","name":"Skiff cursor","vid":0x1209,"pid":0x0001,"bus":"usb","descriptor":["# + TvLink.mouseDescriptor + "]}\n")
                    hid = m
                }
                do {
                    // A report moves at most 127 either way: a bigger move goes as several.
                    var x = dx, y = dy, w = wheel
                    repeat {
                        let sx = min(max(x, -127), 127), sy = min(max(y, -127), 127), sw = min(max(w, -127), 127)
                        try await m.write(#"{"id":1,"command":"report","report":["# + "\(buttons),\(sx & 0xff),\(sy & 0xff),\(sw & 0xff)]}\n")
                        x -= sx; y -= sy; w -= sw
                    } while x != 0 || y != 0 || w != 0
                } catch {
                    // The TV ended the command: a new mouse at the next move.
                    m.close()
                    hid = nil
                    throw error
                }
            }
        }

        func close() {
            hid?.close()
            tv.close()
        }
    }

    /** A mouse's HID report descriptor: three buttons, then X, Y and the wheel, each a relative byte. */
    fileprivate static let mouseDescriptor = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x05, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
        0xC0, 0xC0,
    ].map { String(format: "0x%02x", $0) }.joined(separator: ",")

    /** A connected remote (it asks the TV to allow this phone, the first time). */
    static func remote(_ host: String) async throws -> Remote {
        try await lock.withLock {
            let tv = try await Adb.connect(host: host, port: port, answer: 60)
            do {
                _ = try await tv.shell("true")    // connects now: the first key shouldn't wait for it
                return Remote(tv: tv)
            } catch {
                tv.close()
                throw error
            }
        }
    }

    /** The TV apps that open `link`, without the ones that open any web page (browsers…). */
    static func linkApps(_ host: String, _ link: String) async throws -> [LinkApp] {
        try await withTv(host) { try await linkAppsOn($0, Links.forTv(link)) }
    }

    private static func linkAppsOn(_ tv: Adb, _ link: String) async throws -> [LinkApp] {
        let query = "cmd package query-activities --brief -a android.intent.action.VIEW -d"
        let out = try await tv.shell("\(query) \(q(link)); echo '\(split)'; \(query) 'https://example.com/'").output
        let generic = Set(components(out.after(split, missing: "")))
        var seen = Set<String>()
        let apps = components(out.before(split))
            .filter { !generic.contains($0) && seen.insert($0.before("/")).inserted }
            .map { LinkApp(pkg: $0.before("/"), component: $0) }
        return Rules.shared.preferred(link, apps) { $0.pkg }
    }

    /** Opens `link` on the TV in `component` (nil = the first app that opens it), started with its rule's flags. */
    @discardableResult
    static func openLink(_ host: String, _ link: String, component: String?) async throws -> String {
        try await withTv(host) { tv in
            let tvLink = Links.forTv(link)
            let apps = try await linkAppsOn(tv, tvLink)
            guard let target = apps.first(where: { $0.component == component }) ?? apps.first else {
                throw TvError.other("No app on the TV opens \(Links.site(link)) links.")
            }
            let flags = "0x" + String(Rules.shared.flags(link), radix: 16)
            let r = try await tv.shell("am start -a android.intent.action.VIEW -d \(q(tvLink)) -n \(q(target.component)) -f \(flags)")
            let out = r.allOutput.trimmed
            if r.exitCode != 0 || out.contains("Error") { throw TvError.other(out.isEmpty ? "The TV said no (exit \(r.exitCode))." : out) }
            return out
        }
    }

    /** "com.nuvio.tv/.MainActivity" → "com.nuvio.tv/com.nuvio.tv.MainActivity", from query-activities' lines. */
    static func components(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map(\.trimmed)
            .filter { $0.contains("/") && !$0.contains(" ") && !$0.contains("=") }
            .map { c in
                let pkg = c.before("/"), cls = c.after("/")
                return pkg + "/" + (cls.hasPrefix(".") ? pkg + cls : cls)
            }
    }

    private static func source(_ installer: String?) -> String {
        switch installer {
        case "com.android.vending": return "Play Store"
        case "com.google.android.packageinstaller", "com.android.packageinstaller": return "Installed from an APK"
        case nil, "null", "com.android.shell": return "Installed with ADB"
        default: return installer ?? ""
        }
    }

    /** The shell command, with every value quoted for the TV's shell. Stremio: its link to the stream list. */
    static func command(_ t: Title, component: String, stremio: Bool = false) -> String {
        var s = "am start -n \(q(component)) -f 0x14000000"
        if stremio {
            s += " -a android.intent.action.VIEW -d \(q(t.stremioLink(streams: true)))"
            return s
        }
        s += " --es contentId \(q(t.imdbId))"
        s += " --es contentType \(t.series ? "series" : "movie")"
        s += " --es videoId \(q(t.videoId))"
        s += " --es launchMode stream"
        s += " --es name \(q(t.name))"
        if t.series { s += " --ei season \(t.season) --ei episode \(t.episode)" }
        return s
    }

    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /** Opens the title in `component` (nil = the first app found). Returns the TV's answer. */
    @discardableResult
    static func open(_ host: String, _ t: Title, component: String?) async throws -> String {
        try await withTv(host) { tv in
            let apps = try await detect(tv)
            guard let target = apps.first(where: { $0.component == component }) ?? apps.first else {
                throw TvError.other("There's no Nuvio or Stremio app on that TV.")
            }
            let r = try await tv.shell(command(t, component: target.component, stremio: target.stremio))
            let out = r.allOutput.trimmed
            if r.exitCode != 0 || out.contains("Error") { throw TvError.other(out.isEmpty ? "The TV said no (exit \(r.exitCode))." : out) }
            return out
        }
    }
}
