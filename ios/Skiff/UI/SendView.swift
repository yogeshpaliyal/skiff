import SwiftUI

/**
 * The main screen: the TV (one chip), what to watch (search a title, or paste a link: IMDb, Trakt, JioHotstar…), the
 * title or link found, and Play, with the remote beside it. (MainActivity.kt)
 */
struct SendView: View {
    @Bindable var model: SendModel
    @FocusState private var searchFocused: Bool
    @State private var updates = Updates.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tvChip
                    if model.needsSetup { connectCard }
                    searchBox
                    searchResults
                    recent
                    if model.linkOk { linkSection }
                    titleSection
                    openWith
                    if let s = model.status { NoteCard(text: s, error: model.failed).transition(.opacity) }
                    Text("The phone and the TV on the same Wi-Fi.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .animation(.default, value: model.status)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Skiff")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { model.showLibrary = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("History and saved")
                    Button { model.showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .overlay(alignment: .topTrailing) {
                                if updates.update != nil { Circle().fill(.red).frame(width: 8, height: 8).offset(x: 3, y: -3) }
                            }
                    }
                    .accessibilityLabel(updates.update != nil ? "Settings: an update is available" : "Settings")
                }
            }
            .safeAreaInset(edge: .bottom) { playBar }
            .navigationDestination(isPresented: $model.showLibrary) {
                LibraryView(library: model.library, onOpen: { model.pick($0, play: false) }, onPlay: { model.pick($0, play: true) })
            }
            .navigationDestination(isPresented: $model.showSettings) {
                SettingsView(host: model.host.trimmed, tvName: model.tvName, startOnActivity: model.showActivity)
            }
            .fullScreenCover(isPresented: $model.showRemote) {
                RemoteView(host: model.host.trimmed, tvName: model.tvName) { model.showRemote = false }
            }
            .sheet(isPresented: $model.showTvSheet) { tvSheet }
            .sheet(isPresented: $model.showAppSheet) { appSheet }
        }
        .onAppear { model.onAppear() }
        .onChange(of: model.effectKeys) { model.sync() }
        .onChange(of: model.showRemote) { _, on in if !on { model.screensClosed() } }
        .onChange(of: model.showSettings) { _, on in if !on { model.showActivity = false; model.screensClosed() } }
    }

    // MARK: The TV

    private var tvChip: some View {
        Button { model.showTvSheet = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "tv")
                Text(model.tvStatus).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Change TV")
    }

    private var connectCard: some View {
        PairCard(
            host: model.host.trimmed,
            title: "Connect to \(model.tvLabel)",
            intro: model.adb == .notAllowed
                ? "\(model.tvLabel) is asking “Allow USB debugging?”: allow it (tick Always allow), then Check again. Or pair instead: the TV shows a code, you type it here."
                : "One time only: the TV shows a code, you type it here. Nothing to change in the TV's settings.",
            onPaired: { model.connectionVersion += 1 }
        ) {
            Text("Already use USB debugging (Developer options)? Turn it on, then check again.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { model.adbRun += 1 } label: { Label("Check again", systemImage: "arrow.clockwise") }
        }
    }

    // MARK: What to watch

    private var searchBox: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search a title, or paste a link", text: Binding(get: { model.input }, set: { model.onInput($0) }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit { if model.query.count >= 2 { model.searchNow += 1 } }
            if !model.input.isEmpty {
                Button { model.clear() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Clear")
            } else {
                Button("Paste") { model.paste() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
    }

    @ViewBuilder private var searchResults: some View {
        let q = model.query
        if q.count >= 2 {
            let current = model.hitsFor == q
            if current && !model.hits.isEmpty {
                ForEach(Array(model.hits.prefix(model.shownHits).enumerated()), id: \.element.id) { i, h in
                    Button { model.pickHit(h); searchFocused = false } label: {
                        HStack(spacing: 14) {
                            Poster(url: h.poster, symbol: h.series ? "rectangle.stack" : "film", width: 46, height: 68)
                            VStack(alignment: .leading) {
                                Text(h.name).font(.headline).lineLimit(2).foregroundStyle(.primary)
                                Text([h.series ? "Series" : "Movie", h.year].compactMap { $0 }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    // Near the end with more found than shown: the next page.
                    .onAppear { if i == model.shownHits - 1 { model.showMoreHits() } }
                }
            } else if model.findingTitles || !current {
                HStack(spacing: 12) { ProgressView(); Text("Searching…").font(.subheadline) }
            } else {
                Text("No title called “\(q)”. Try fewer words, or paste its IMDb link.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var recent: some View {
        let items = model.library.entries.filter(\.inHistory).prefix(3)
        if !model.idOk && !model.linkOk && model.query.count < 2 && !items.isEmpty {
            SectionHeader(text: "Recent") { Button("See all") { model.showLibrary = true } }
            ForEach(Array(items)) { e in
                EntryRow(entry: e, onOpen: { model.pick(e, play: false) }, onPlay: { model.pick(e, play: true) },
                         onToggleSaved: { model.library.setSaved(e.title, meta: nil, saved: !e.saved) })
            }
        }
    }

    // MARK: The link or title found

    @ViewBuilder private var linkSection: some View {
        if let l = model.link {
            ArtCard(image: model.page?.image, loading: model.page == nil) {
                Text(model.page?.title ?? "").font(.title2.bold()).lineLimit(3)
                HStack { Pill(text: Links.site(l)); if let by = model.page?.by { Pill(text: by) } }
            }
            let saved = model.library.entries.contains { $0.imdbId == l && $0.saved }
            SaveButton(saved: saved) {
                model.library.setLinkSaved(l, page: model.page,
                                           app: (model.linkApps.first { $0.component == model.linkComponent })?.name, saved: !saved)
            }
        }
    }

    @ViewBuilder private var titleSection: some View {
        if model.lookingUp {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else if let m = model.meta {
            ArtCard(image: m.background, loading: false, poster: m.poster) {
                Text(m.name).font(.title2.bold()).lineLimit(3)
                let details = [m.year, m.genres.isEmpty ? nil : m.genres.joined(separator: ", "), m.runtime].compactMap { $0 }
                if !details.isEmpty { Text(details.joined(separator: " · ")).font(.subheadline).opacity(0.85) }
                HStack { Pill(text: m.series ? "Series" : "Movie"); if let r = m.rating { Pill(text: "★ \(r)") } }
            }
        } else if model.idOk && model.notFound {
            NoteCard(text: "Not on Cinemeta. Type the title below.", error: true)
        }
        if model.idOk {
            if model.meta != nil || !model.name.trimmed.isEmpty {
                let saved = model.library.entries.contains { $0.imdbId == model.imdbId && $0.saved }
                SaveButton(saved: saved) {
                    let t = Title(imdbId: model.imdbId, name: model.name.trimmed.isEmpty ? (model.meta?.name ?? "") : model.name,
                                  series: model.series, season: model.season, episode: model.episode)
                    model.library.setSaved(t, meta: model.meta, saved: !saved)
                }
            }
            Picker("Type", selection: Binding(get: { model.series }, set: { model.series = $0; model.keepType = true })) {
                Label("Movie", systemImage: "film").tag(false)
                Label("Series", systemImage: "rectangle.stack").tag(true)
            }
            .pickerStyle(.segmented)
            if model.series {
                HStack(spacing: 12) {
                    NumberStepper(label: "Season", value: $model.season)
                    NumberStepper(label: "Episode", value: $model.episode)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.editName || model.notFound {
                TextField("Name shown in Nuvio", text: Binding(get: { model.name }, set: { model.name = $0; model.autoName = false }))
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Button { model.editName = true } label: { Label("Edit the name", systemImage: "pencil") }
            }
        }
    }

    // MARK: Open with

    @ViewBuilder private var openWith: some View {
        if model.hostOk && (model.idOk || model.linkOk) {
            let chosenLink = model.linkApps.first(where: { $0.component == model.linkComponent }) ?? model.linkApps.first
            let chosenApp = model.apps.first(where: { $0.component == model.appComponent })
            let chosen: String? = model.linkOk
                ? chosenLink?.name
                : chosenApp.map { app in [app.name, app.version].compactMap { $0 }.joined(separator: " ") }
            let loading = model.linkOk ? model.linkAppsLoading : model.appsLoading
            let line: String? = {
                if model.useAdb == false {
                    if model.linkOk { return "Opens in the TV's app for \(model.link.map(Links.site) ?? "")" }
                    return model.pairedStremio ? "Opens in Stremio, at the streams" : "Opens in Nuvio, on the title's page"
                }
                if model.useAdb == nil { return nil }
                if loading { return "Checking which app opens it…" }
                if let chosen { return "Opens in \(chosen)" }
                if model.linkOk { return "No app on \(model.tvLabel) opens \(model.link.map(Links.site) ?? "") links" }
                return model.appsError ?? "No Nuvio or Stremio app on \(model.tvLabel)"
            }()
            let pairedChoice = model.useAdb == false && !model.linkOk
            let problem = model.useAdb == true && !loading && chosen == nil
            if let line {
                Button { model.showAppSheet = true } label: {
                    HStack(spacing: 12) {
                        if loading { ProgressView() } else { Image(systemName: "tv") }
                        Text(line).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(problem ? Color.red.opacity(0.15) : Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!(pairedChoice || (model.useAdb == true && !loading)))
            }
        }
    }

    // MARK: Play

    private var playBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { model.showRemote = true } label: {
                    Image(systemName: "av.remote").font(.title2).frame(width: 60, height: 60)
                }
                .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 20))
                .disabled(!model.hostOk)
                .accessibilityLabel("Remote")
                Button { searchFocused = false; model.openOnTv() } label: {
                    HStack {
                        if model.busy { ProgressView().tint(.white) } else { Image(systemName: "play.fill") }
                        Text("Play").font(.title3.bold())
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 20))
                .disabled(!model.ready)
            }
            if let h = model.hint { Text(h).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: Sheets

    private var tvSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.tvs.isEmpty {
                        Panel {
                            HStack(spacing: 16) {
                                if model.searchingTvs { ProgressView() } else { Image(systemName: "tv").font(.title) }
                                Text(model.searchingTvs ? "Looking for TVs on your Wi-Fi…" : "No TV found on this Wi-Fi. Enter its address.")
                            }
                        }
                    }
                    ForEach(model.tvs) { tv in
                        let paired = Atv.isPaired(tv.host)
                        ChoiceCard(title: tv.name,
                                   subtitle: tv.ready ? tv.host : paired ? "\(tv.host) · paired" : "\(tv.host) · pair it from the remote",
                                   symbol: "tv", selected: tv.host == model.host.trimmed) { model.pick(tv: tv) }
                    }
                    if model.manual || (!model.searchingTvs && !model.tvs.contains(where: \.ready)) {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("TV address (192.168.1.7)", text: Binding(get: { model.host }, set: { model.host = $0; model.tvName = "" }))
                                .keyboardType(.numbersAndPunctuation)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(14)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text("On the TV: Settings → Network & Internet").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if !model.manual && model.tvs.contains(where: \.ready) {
                        Button("Enter an address instead") { model.manual = true }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Your TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !model.searchingTvs { Button { model.findTvs() } label: { Label("Search again", systemImage: "arrow.clockwise") } }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.showTvSheet = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var appSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.useAdb == false && !model.linkOk {
                        // Paired: the TV doesn't say which apps it has, so these are what Skiff knows how to open.
                        ChoiceCard(title: "Nuvio", subtitle: "Opens the title's page", symbol: "play.fill", selected: !model.pairedStremio) {
                            model.pairedStremio = false; model.showAppSheet = false
                        }
                        ChoiceCard(title: "Stremio", subtitle: "Opens the streams for it (the episode, for a series)", symbol: "play.fill",
                                   selected: model.pairedStremio) {
                            model.pairedStremio = true; model.showAppSheet = false
                        }
                    } else if model.linkOk {
                        if model.linkAppsLoading {
                            Panel { HStack(spacing: 16) { ProgressView(); Text("Checking which app on \(model.tvLabel) opens it…") } }
                        } else if model.linkApps.isEmpty {
                            NoteCard(text: "No app on \(model.tvLabel) opens \(model.link.map(Links.site) ?? "") links. Install its TV app, then try again.", error: true)
                        } else {
                            ForEach(model.linkApps) { app in
                                ChoiceCard(title: app.name, subtitle: app.pkg, symbol: "play.fill", selected: app.component == model.linkComponent) {
                                    model.linkComponent = app.component; model.showAppSheet = false
                                }
                            }
                        }
                    } else if model.appsLoading {
                        Panel { HStack(spacing: 16) { ProgressView(); Text("Checking the apps on \(model.tvLabel)… The first time, allow USB debugging on the TV.") } }
                    } else if let e = model.appsError {
                        NoteCard(text: e, error: true)
                    } else {
                        ForEach(model.apps) { app in
                            ChoiceCard(title: [app.name, app.version].compactMap { $0 }.joined(separator: " · "), subtitle: "\(app.source) · \(app.pkg)",
                                       symbol: "play.fill", selected: app.component == model.appComponent) {
                                model.appComponent = app.component; model.showAppSheet = false
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Open with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.useAdb == true {
                        Button { model.adbRun += 1; if model.linkOk { model.linkRun += 1 } else { model.appsRun += 1 } } label: {
                            Label("Check again", systemImage: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { model.showAppSheet = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/** A title or link: its picture behind (darkened), the poster, and what's said about it. */
struct ArtCard<Content: View>: View {
    let image: String?
    let loading: Bool
    var poster: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let onArt = image != nil
        HStack(spacing: 16) {
            if let poster, let u = URL(string: poster) {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.1) }
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                if loading { ProgressView() } else { content }
            }
            .foregroundStyle(onArt ? Color.white : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .background {
            ZStack {
                Color(.secondarySystemGroupedBackground)
                if let image, let u = URL(string: image) {
                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct SaveButton: View {
    let saved: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(saved ? "Saved for later" : "Save for later", systemImage: saved ? "bookmark.fill" : "bookmark")
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.bordered)
        .tint(saved ? Color.accentColor : Color.secondary)
    }
}
