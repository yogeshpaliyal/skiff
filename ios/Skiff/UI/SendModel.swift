import Foundation
import Observation
import UIKit

/**
 * The main screen's state and what it does: the TV picked (found on the Wi-Fi), what to watch (a title by name, an
 * IMDb id or page, another site's title page, or any other link), and opening it on the TV, by USB debugging or by
 * pairing. A port of MainActivity.kt's RemoteScreen; its LaunchedEffects are the `effect`s in `sync()`, rerun when
 * their keys change.
 */
@MainActor @Observable
final class SendModel {
    static let searchPage = 8

    let library = Library.shared
    let log = ActivityLog.shared
    private let prefs = UserDefaults.standard

    // MARK: Screens

    var showLibrary = false
    var showRemote = false
    var showSettings = false
    var showActivity = false
    var showTvSheet = false
    var showAppSheet = false

    // MARK: The TV

    var host: String { didSet { if host != oldValue { connectionVersion += 1 } } }
    /** The TV picked from the list, by name: if the router gives it a new address, we follow it. */
    var tvName: String
    var tvs: [TvFinder.Tv] = []
    var searchingTvs = true
    var manual = false
    @ObservationIgnored private var finder: TvFinder?
    /** Bumped when pairing or the connection settings may have changed (back from the remote or Settings). */
    var connectionVersion = 0

    // The Nuvio apps on that TV, and the one to open titles in.
    var apps: [TvLink.NuvioApp] = []
    var appsLoading = false
    var appsError: String?
    var appsRun = 0
    var appComponent: String?
    /** Over pairing there's no list of the TV's apps: titles open in the one you pick, Nuvio or Stremio. */
    var pairedStremio: Bool { didSet { prefs.set(pairedStremio ? "stremio" : "nuvio", forKey: "remote.titleApp") } }

    var adb: TvLink.AdbState?      // nil: checking
    var adbRun = 0

    // MARK: The title

    var series = false
    /** The box's text when it's not a link: an IMDb id, or words to search. */
    var imdbId = ""
    var name = ""
    var meta: Meta.Found?
    var season = 1
    var episode = 1
    var busy = false
    var status: String?
    var failed = false
    var autoName = true
    var editName = false
    var lookingUp = false
    var notFound = false
    var openWhenKnown = false
    var shareRun = 0
    var keepType = false
    var hits: [Meta.Hit] = []
    var hitsFor = ""
    var shownHits = SendModel.searchPage
    var findingTitles = false
    var searchNow = 0
    @ObservationIgnored private var searchedNow = 0

    // Or any other link (JioHotstar, YouTube…).
    var link: String?
    var linkTitle = ""
    var recordLink = false
    var page: Links.Page?
    var linkApps: [TvLink.LinkApp] = []
    var linkAppsLoading = false
    var linkComponent: String?
    var linkRun = 0

    // A title page of another site (Trakt…): looked up before it's a title like any other.
    var sourceLink: String?
    var episodeKnown = false

    init() {
        host = prefs.string(forKey: "remote.host") ?? ""
        tvName = prefs.string(forKey: "remote.tvName") ?? ""
        appComponent = prefs.string(forKey: "remote.app")
        linkComponent = prefs.string(forKey: "remote.linkApp")
        pairedStremio = prefs.string(forKey: "remote.titleApp") == "stremio"
    }

    // MARK: Derived

    var hostOk: Bool { !host.trimmed.isEmpty }
    var idOk: Bool { Title.isImdbId(imdbId) }
    var linkOk: Bool { link != nil }
    var paired: Bool { _ = connectionVersion; return hostOk && Atv.isPaired(host) }
    var linkVia: Connection.Mode { _ = connectionVersion; return Connection.link(host) }
    /** Neither way works yet (not paired, USB debugging off or this phone not allowed): the connect card, first. */
    var needsSetup: Bool { hostOk && linkVia == .auto && !paired && adb != nil && adb != .allowed }
    /** true: USB debugging; false: pairing; nil: still checking, or not connected yet. */
    var useAdb: Bool? {
        switch linkVia {
        case .adb: return true
        case .pairing: return false
        case .auto:
            if adb == nil || needsSetup { return nil }
            return adb == .allowed
        }
    }
    var linkByPairing: Bool { linkOk && useAdb == false }
    var titleByPairing: Bool { idOk && !linkOk && useAdb == false }
    var titleApp: String {
        if useAdb == false { return pairedStremio ? "Stremio" : "Nuvio" }
        return (apps.first { $0.component == appComponent } ?? apps.first)?.name ?? "Nuvio"
    }
    var ready: Bool { hostOk && useAdb != nil && (idOk || (linkOk && (!linkApps.isEmpty || linkByPairing))) && !busy }
    var tvLabel: String { tvName.isEmpty ? (host.trimmed.isEmpty ? "the TV" : host.trimmed) : tvName }
    /** The words to search for: what's typed when it's not a link or an IMDb id. */
    var query: String { link == nil && sourceLink == nil && !idOk ? imdbId.trimmed : "" }
    /** The box shows the other site's link, the link, or what's typed. */
    var input: String { sourceLink ?? link ?? imdbId }

    var tvStatus: String {
        if hostOk {
            if useAdb == false { return "\(tvLabel) · \(paired ? "paired" : "not paired yet")" }
            switch adb {
            case nil: return "\(tvLabel) · checking…"
            case .allowed: return "\(tvLabel) · USB debugging"
            default: return "\(tvLabel) · not connected yet"
            }
        }
        return searchingTvs ? "Looking for TVs…" : "Pick a TV"
    }

    var hint: String? {
        if busy { return nil }
        if !hostOk { return "Pick a TV above" }
        if needsSetup { return "Connect to \(tvLabel) above" }
        if linkByPairing { return nil }
        if linkOk && linkAppsLoading { return "Checking which TV app opens it…" }
        if linkOk && linkApps.isEmpty { return "No app on \(tvLabel) opens \(link.map(Links.site) ?? "") links" }
        if !idOk && !linkOk { return "Share a page (IMDb, JioHotstar, YouTube…), or paste its link" }
        return nil
    }

    // MARK: Effects

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var keys: [String: String] = [:]

    /** Reruns an effect when its key changed (cancelling the one running), as Compose's LaunchedEffect does. */
    private func effect(_ name: String, _ key: String, _ body: @escaping @MainActor () async -> Void) {
        if keys[name] == key { return }
        keys[name] = key
        tasks[name]?.cancel()
        tasks[name] = Task { await body() }
    }

    /** Everything the effects depend on: when it changes, `sync()` runs. */
    var effectKeys: String {
        [host.trimmed, "\(adbRun)", "\(appsRun)", "\(useAdb.map { "\($0)" } ?? "-")", link ?? "-", "\(shareRun)", "\(linkRun)",
         sourceLink ?? "-", imdbId, "\(searchNow)", "\(connectionVersion)"].joined(separator: "|")
    }

    /** Starts (or restarts) what changed: the checks, lookups and searches. */
    func sync() {
        let h = host.trimmed
        effect("adb", "\(h)|\(adbRun)|\(connectionVersion)") { [weak self] in await self?.checkAdb() }
        effect("apps", "\(h)|\(appsRun)|\(String(describing: useAdb))") { [weak self] in await self?.loadApps() }
        effect("page", "\(link ?? "")|\(shareRun)") { [weak self] in await self?.loadPage() }
        effect("linkApps", "\(link ?? "")|\(h)|\(shareRun)|\(linkRun)|\(String(describing: useAdb))") { [weak self] in await self?.loadLinkApps() }
        effect("source", "\(sourceLink ?? "")|\(shareRun)") { [weak self] in await self?.resolveSource() }
        effect("lookup", "\(imdbId)|\(shareRun)") { [weak self] in await self?.lookupTitle() }
        effect("search", "\(query)|\(searchNow)") { [weak self] in await self?.searchTitles() }
    }

    func onAppear() {
        if finder == nil {
            finder = TvFinder { [weak self] found in self?.found(found) }
        }
        findTvs()
        Task { await Rules.shared.refresh() }
        Task { try? await Updates.shared.check() }
        sync()
    }

    func findTvs() {
        finder?.start()
        searchingTvs = true
        effect("searching", "\(Date().timeIntervalSince1970)") { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { self?.searchingTvs = false }
        }
    }

    private func found(_ found: [TvFinder.Tv]) {
        tvs = found
        // A paired TV at a new address (the router moved it) keeps its pairing, found by its name.
        for tv in found { Atv.adopt(tv.host, name: tv.name) }
        func usable(_ tv: TvFinder.Tv) -> Bool { tv.ready || Atv.isPaired(tv.host) }
        if let same = found.first(where: { usable($0) && $0.name == tvName }) {
            host = same.host
        } else if host.trimmed.isEmpty {
            let usableOnes = found.filter(usable)
            if let one = usableOnes.count == 1 ? usableOnes.first : (found.count == 1 ? found.first : nil) {
                host = one.host
                tvName = one.name
            }
        }
        connectionVersion += 1
    }

    func pick(tv: TvFinder.Tv) {
        host = tv.host
        tvName = tv.name
        manual = false
        showTvSheet = false
    }

    private func checkAdb() async {
        adb = nil
        let h = host.trimmed
        if h.isEmpty { return }
        try? await Task.sleep(nanoseconds: 500_000_000)     // typing an address: wait for the whole of it
        if Task.isCancelled { return }
        let state = await TvLink.check(h)
        if Task.isCancelled { return }
        adb = state
        if paired { Atv.rememberName(h, name: tvName) }
    }

    /** A TV picked: which Nuvio apps it has (connecting is also when it asks to allow this phone, the first time). */
    private func loadApps() async {
        apps = []
        appsError = nil
        let h = host.trimmed
        if h.isEmpty || useAdb != true { return }
        appsLoading = true
        defer { appsLoading = false }
        do {
            let found = try await TvLink.apps(h)
            if Task.isCancelled { return }
            apps = found
            if !found.contains(where: { $0.component == appComponent }) { appComponent = found.first?.component }
            if found.isEmpty { appsError = "There's no Nuvio or Stremio app on \(tvLabel). Install one, then check again." }
        } catch {
            if Task.isCancelled { return }
            appsError = "Couldn't reach \(tvLabel): \(error.localizedDescription)"
        }
    }

    /** A link: its name and picture (the page, or the link itself). */
    private func loadPage() async {
        page = nil
        guard let l = link else { return }
        if !recordLink { try? await Task.sleep(nanoseconds: 600_000_000) }    // typing: wait for the whole link
        if Task.isCancelled { return }
        let p = await Links.page(l, fallback: linkTitle)
        if Task.isCancelled || link != l { return }
        page = p
        if recordLink { library.useLink(l, page: p, app: nil, played: false) }
    }

    /** Which TV apps open the link; shared: opened as soon as there's an app for it. */
    private func loadLinkApps() async {
        linkApps = []
        guard let l = link, hostOk, let viaAdb = useAdb else { return }
        if !viaAdb {
            // Over pairing: no app to look up, the TV picks it.
            if openWhenKnown {
                openWhenKnown = false
                if !busy { openLinkOnTv(byPairing: true) }
            }
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }
        linkAppsLoading = true
        do {
            let found = try await TvLink.linkApps(host.trimmed, l)
            if Task.isCancelled { linkAppsLoading = false; return }
            linkApps = found
            if !found.contains(where: { $0.component == linkComponent }) { linkComponent = found.first?.component }
        } catch {
            if Task.isCancelled { linkAppsLoading = false; return }
            failed = true
            status = "Couldn't reach \(tvLabel): \(error.localizedDescription)"
        }
        linkAppsLoading = false
        if openWhenKnown {
            openWhenKnown = false
            if !linkApps.isEmpty && !busy { openLinkOnTv(byPairing: false) }
        }
    }

    /** Another site's page: its IMDb id (and the episode), then the title as if its IMDb page was shared. */
    private func resolveSource() async {
        guard let l = sourceLink, let source = TitleSources.of(l) else { return }
        if !openWhenKnown { try? await Task.sleep(nanoseconds: 600_000_000) }    // typing: wait for the whole link
        if Task.isCancelled { return }
        lookingUp = true
        let found = try? await source.resolve(l)
        if Task.isCancelled { return }
        lookingUp = false
        sourceLink = nil
        guard let found else {
            imdbId = source.searchFor(l) ?? ""
            openWhenKnown = false
            status = "Couldn't find that \(source.name) page's title. Pick it below."
            return
        }
        let t = found.title
        imdbId = t.imdbId
        name = ""
        autoName = true
        series = t.series
        keepType = true
        season = t.season
        episode = t.episode
        episodeKnown = found.episodeKnown
        shareRun += 1
    }

    /** The id gives the title, its art and whether it's a movie or a series (Cinemeta). */
    private func lookupTitle() async {
        let knownEpisode = episodeKnown
        episodeKnown = false
        notFound = false
        guard idOk else {
            meta = nil
            return
        }
        lookingUp = true
        try? await Task.sleep(nanoseconds: 300_000_000)     // typing: wait for the whole id
        if Task.isCancelled { return }
        let found = try? await Meta.lookup(imdbId.trimmed)
        if Task.isCancelled { return }
        lookingUp = false
        meta = found
        guard let found else {
            notFound = true
            editName = true
            openWhenKnown = false
            return
        }
        if autoName || name.trimmed.isEmpty {
            name = found.name
            autoName = true
        }
        if !keepType { series = found.series }
        library.use(Title(imdbId: imdbId.trimmed, name: name, series: series, season: season, episode: episode), meta: found, played: false)
        if openWhenKnown {
            openWhenKnown = false
            if found.series && !knownEpisode {
                status = "Pick the season and episode, then play it."
            } else if hostOk && !busy {
                openOnTv()
            } else {
                status = "Pick your TV, then play it."
            }
        }
    }

    /** Typed words that aren't a link or an IMDb id: a title search (Cinemeta), its results under the box. */
    private func searchTitles() async {
        let q = query
        if q.count < 2 {
            hits = []
            hitsFor = ""
            findingTitles = false
            return
        }
        if hitsFor == q && !hits.isEmpty { return }     // Search pressed: already found
        if searchNow == searchedNow { try? await Task.sleep(nanoseconds: 350_000_000) }    // typing: once the word is there
        if Task.isCancelled { return }
        searchedNow = searchNow
        findingTitles = true
        guard let found = try? await Meta.search(q) else { return }    // typed on meanwhile: not these
        if Task.isCancelled { return }
        hits = found
        hitsFor = q
        shownHits = SendModel.searchPage
        findingTitles = false
    }

    func showMoreHits() {
        if !hitsFor.isEmpty && shownHits < hits.count { shownHits += SendModel.searchPage }
    }

    // MARK: Input

    /** The box changed: another site's title page, an IMDb link or id, any other link, or words to search. */
    func onInput(_ v: String) {
        let id = Title.idIn(v)
        sourceLink = nil
        if TitleSources.of(v) != nil {
            link = nil; imdbId = ""; sourceLink = v.trimmed; openWhenKnown = false
        } else if let id {
            link = nil; imdbId = id; keepType = false
        } else if Links.isLink(v.trimmed) {
            link = v.trimmed; linkTitle = ""; recordLink = false; imdbId = ""
        } else {
            link = nil; imdbId = v; keepType = false     // as typed: trimming would eat the space between words
        }
    }

    func paste() {
        guard let t = UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString else { return }
        let id = Title.idIn(t)
        let l = Links.linkIn(t)
        if let l, TitleSources.of(l) != nil {
            link = nil; imdbId = ""; sourceLink = l; openWhenKnown = false
        } else if let id {
            link = nil; imdbId = id; autoName = true; keepType = false
        } else if let l {
            link = l; linkTitle = ""; recordLink = true; imdbId = ""
        }
    }

    /** Start over: the box, the title or link found, its episode, and the last message. */
    func clear() {
        link = nil; sourceLink = nil; linkTitle = ""; recordLink = false; page = nil
        imdbId = ""; name = ""; meta = nil; series = false; season = 1; episode = 1
        autoName = true; keepType = false; editName = false; notFound = false; openWhenKnown = false
        status = nil; failed = false; hits = []; hitsFor = ""
    }

    func pickHit(_ h: Meta.Hit) {
        imdbId = h.imdbId
        name = h.name
        series = h.series
        autoName = true
        keepType = false
        hits = []
        hitsFor = ""
        status = nil
    }

    // MARK: Shared, opened from a link or a quick action

    /** skiff://share?text=…&subject=… (the share extension), skiff://remote, skiff://library. */
    func open(url: URL) {
        guard url.scheme == "skiff" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "share":
            let text = items.first { $0.name == "text" }?.value
            let subject = items.first { $0.name == "subject" }?.value
            if let s = Title.fromShared(text: text, subject: subject) { shared(s) }
        default:
            openScreen(url.host)
        }
    }

    func openScreen(_ screen: String?) {
        guard let screen else { return }
        showLibrary = screen == "library"
        showSettings = screen == "settings" || screen == "activity"
        showActivity = screen == "activity"
        showRemote = screen == "remote"
    }

    /** A shared IMDb page fills in the id (and the title); another site's, once it's looked up; any other link. */
    func shared(_ s: Title.Shared) {
        showLibrary = false; showRemote = false; showSettings = false
        status = nil
        failed = false
        openWhenKnown = true
        if let l = s.link, TitleSources.of(l) != nil {
            sourceLink = l; link = nil; imdbId = ""; name = ""
        } else if let l = s.link {
            sourceLink = nil; link = l; linkTitle = s.name; recordLink = true; imdbId = ""
        } else {
            sourceLink = nil; link = nil; imdbId = s.imdbId
            if !s.name.isEmpty { name = s.name; autoName = true }
            if let ser = s.series { series = ser }
            keepType = false
        }
        shareRun += 1
    }

    /** An entry from the library back on the main screen, as it was used; `play`: straight to the TV. */
    func pick(_ e: Library.Entry, play: Bool) {
        showLibrary = false
        sourceLink = nil
        if let l = e.link {
            link = l
            linkTitle = e.name
            recordLink = true
            imdbId = ""
            failed = false
            status = nil
            openWhenKnown = play     // played once the TV says which app opens it
            shareRun += 1
            return
        }
        link = nil
        imdbId = e.imdbId
        name = e.name
        autoName = false
        series = e.series
        keepType = true
        season = e.season
        episode = e.episode
        editName = false
        failed = false
        status = nil
        if play {
            if hostOk && !busy { openOnTv() } else { status = "Pick your TV, then play it." }
        }
    }

    // MARK: Opening it on the TV

    private func remember() {
        prefs.set(host.trimmed, forKey: "remote.host")
        prefs.set(tvName, forKey: "remote.tvName")
        prefs.set(appComponent, forKey: "remote.app")
        prefs.set(linkComponent, forKey: "remote.linkApp")
    }

    func openLinkOnTv(byPairing: Bool? = nil) {
        guard let l = link else { return }
        let pairing = byPairing ?? linkByPairing
        busy = true
        failed = false
        status = pairing ? "Connecting…" : "Connecting… The first time, accept “Allow USB debugging?” on the TV (tick Always allow)."
        let h = host.trimmed, component = linkComponent, label = tvLabel
        Task {
            defer { busy = false }
            let via = pairing ? Via.pairing : Via.adb
            do {
                if pairing { try await Atv.openLink(h, Links.forTv(l)) } else { try await TvLink.openLink(h, l, component: component) }
                let app = pairing ? nil : (linkApps.first { $0.component == component } ?? linkApps.first)?.name
                let p = page ?? Links.Page(title: linkTitle.trimmed.isEmpty ? Links.site(l) : linkTitle)
                library.useLink(l, page: p, app: app, played: true)
                remember()
                status = app.map { "Opened “\(p.title)” in \($0) on \(label)." } ?? "Opened “\(p.title)” on \(label)."
                log.add(app.map { "Link \(Links.site(l)) → \($0)" } ?? "Link \(Links.site(l))", via: via)
            } catch {
                log.add("Link \(Links.site(l))", via: via, ok: false)
                failed = true
                status = "Couldn't open it: \(error.localizedDescription)"
            }
        }
    }

    func openOnTv() {
        if link != nil { return openLinkOnTv() }
        busy = true
        failed = false
        let pairing = titleByPairing
        let via = pairing ? Via.pairing : Via.adb
        status = pairing ? "Connecting…" : "Connecting… The first time, accept “Allow USB debugging?” on the TV (tick Always allow)."
        let h = host.trimmed, label = tvLabel, app = titleApp, stremio = pairedStremio, component = appComponent
        Task {
            defer { busy = false }
            do {
                var n = name.trimmed
                if n.isEmpty {
                    // Nuvio needs the name for its stream picker (over pairing, only for history).
                    n = (try? await Meta.lookup(imdbId.trimmed))?.name ?? ""
                    if n.isEmpty && !pairing { throw TvError.other("Couldn't find this title's name. Type it in, then try again.") }
                    name = n
                }
                let title = Title(imdbId: imdbId.trimmed, name: n.isEmpty ? imdbId.trimmed : n, series: series, season: season, episode: episode)
                if pairing {
                    // Stremio's link goes to the episode's streams; Nuvio's, to the title's page.
                    try await Atv.openLink(h, stremio ? title.stremioLink(streams: true) : title.nuvioLink)
                } else {
                    try await TvLink.open(h, title, component: component)
                }
                library.use(title, meta: meta, played: true)
                remember()
                let withEpisode = title.name + (title.series ? " S\(title.season) E\(title.episode)" : "")
                if pairing {
                    status = "Opened “\(title.name)” in \(stremio ? "Stremio" : "Nuvio") on \(label): pick a stream there."
                } else if app == "Stremio" {
                    status = "Opened “\(withEpisode)” in Stremio on \(label): pick a stream there."
                } else {
                    status = "Playing “\(withEpisode)” on \(label)."
                }
                log.add("\(app) “\(title.name)”", via: via)
            } catch {
                log.add("\(app) “\(name.trimmed.isEmpty ? imdbId : name.trimmed)”", via: via, ok: false)
                failed = true
                status = "Couldn't open it: \(error.localizedDescription)"
            }
        }
    }

    /** Back from the remote or Settings: pairing or the connection may have changed. */
    func screensClosed() {
        connectionVersion += 1
    }
}
