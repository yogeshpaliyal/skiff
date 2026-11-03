import SwiftUI
import UIKit
import UniformTypeIdentifiers

/**
 * Settings, for the TV picked: Activity; Connection (paired or not, whether its ADB answers, and how the remote and
 * links reach it); ADB tools (a shell command, an APK installed on the TV); Privacy; About. (SettingsScreen.kt)
 */
struct SettingsView: View {
    let host: String
    let tvName: String
    var startOnActivity = false

    @State private var paired = false
    @State private var pairOpen = false
    @State private var remoteVia = Connection.Mode.auto
    @State private var linkVia = Connection.Mode.auto
    @State private var adb: TvLink.AdbState?
    @State private var adbRun = 0
    @State private var showActivity = false

    @State private var command = ""
    @State private var recent: [String] = SettingsView.recentCommands()
    @State private var running = false
    @State private var output: String?
    @State private var outputFailed = false
    @State private var pickingApk = false
    @State private var installing = false
    @State private var installNote: String?
    @State private var installFailed = false

    @State private var updates = Updates.shared
    @State private var checking = false
    @State private var checkNote: String?
    @State private var log = ActivityLog.shared
    @Environment(\.openURL) private var openURL

    private var hostOk: Bool { !host.isEmpty }
    private var tvLabel: String { tvName.isEmpty ? (host.isEmpty ? "the TV" : host) : tvName }
    private var tools: Bool { hostOk && adb == .allowed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                activityCard
                connection
                adbTools
                privacy
                about
                Text("Skiff \(Updates.current) (\(Updates.build))")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 16)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showActivity) { ActivityView() }
        .onAppear {
            paired = hostOk && Atv.isPaired(host)
            remoteVia = Connection.remote(host)
            linkVia = Connection.link(host)
            if startOnActivity { showActivity = true }
        }
        .task(id: "\(host)|\(adbRun)") {
            adb = nil
            guard hostOk else { return }
            let state = await TvLink.check(host)
            if !Task.isCancelled { adb = state }
        }
        .fileImporter(isPresented: $pickingApk, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data, .data]) { result in
            if case .success(let url) = result { install(url) }
        }
    }

    // MARK: Activity

    private var activityCard: some View {
        Button { showActivity = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity").font(.headline).foregroundStyle(.primary)
                    Text(log.entries.first.map { "Last: \($0.what) · \($0.via)" } ?? "What Skiff sends to the TV, and how")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    // MARK: Connection

    @ViewBuilder private var connection: some View {
        SectionHeader(hostOk ? "Connection · \(tvLabel)" : "Connection")
        if !hostOk {
            Text("Pick a TV first, on Skiff's main screen.")
        } else {
            Panel {
                StatusRow(label: "Pairing", value: paired ? "Paired" : "Not paired", good: paired ? true : nil)
                StatusRow(label: "USB debugging", value: adbText, good: adb.map { $0 == .allowed }) {
                    if adb != nil { Button { adbRun += 1 } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Check again") }
                }
                HStack(spacing: 12) {
                    if paired {
                        Button("Forget pairing") {
                            Atv.forget(host, name: tvName)
                            paired = false
                            log.add("Forgot the pairing with \(tvLabel)", via: Via.pairing)
                        }
                        .buttonStyle(.bordered)
                    }
                    if !pairOpen { Button(paired ? "Pair again" : "Pair") { pairOpen = true }.buttonStyle(.borderedProminent) }
                }
            }
            if pairOpen {
                PairCard(host: host, onPaired: { paired = true; pairOpen = false }, onCancel: { pairOpen = false })
            }
            Panel {
                Text("Remote").font(.subheadline.bold())
                modePicker($remoteVia) { Connection.setRemote(host, $0) }
                Text(remoteHelp(remoteVia)).font(.footnote).foregroundStyle(.secondary)
                Text("Links and titles").font(.subheadline.bold()).padding(.top, 4)
                modePicker($linkVia) { Connection.setLink(host, $0) }
                Text(linkHelp(linkVia) + " Over pairing the TV picks a link's app, and a title opens in Nuvio (its page) or Stremio (its streams); over USB debugging you pick the app, the link's rules apply, and Nuvio goes straight to the streams.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var adbText: String {
        switch adb {
        case nil: return "Checking…"
        case .allowed: return "Allowed for this phone"
        case .notAllowed: return "On, but this phone isn't allowed: on the TV, allow it (tick Always allow), then check again"
        case .off: return "Off (Settings → System → Developer options on the TV)"
        }
    }

    private func modePicker(_ value: Binding<Connection.Mode>, _ onChange: @escaping (Connection.Mode) -> Void) -> some View {
        Picker("Via", selection: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; onChange($0) })) {
            ForEach(Connection.Mode.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    private func remoteHelp(_ m: Connection.Mode) -> String {
        switch m {
        case .auto: return "Automatic: keys and text over USB debugging when this phone is allowed, else over pairing."
        case .pairing: return "Only over pairing (the Google TV remote protocol)."
        case .adb: return "Only over USB debugging (ADB)."
        }
    }

    private func linkHelp(_ m: Connection.Mode) -> String {
        m == .auto ? "Automatic: over USB debugging when this phone is allowed (Open with lists the TV's apps), else over pairing." : remoteHelp(m)
    }

    // MARK: ADB tools

    @ViewBuilder private var adbTools: some View {
        SectionHeader("ADB tools")
        if hostOk && adb != nil && adb != .allowed {
            Text("These need USB debugging on \(tvLabel) (Settings → System → Developer options), and this phone allowed.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        Panel {
            Text("Run a command").font(.subheadline.bold())
            Text("As adb shell runs it, on \(tvLabel). It can change or remove anything on the TV: run only what you know.")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("pm list packages -3", text: $command)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { run(command) }
                .disabled(!tools)
                .padding(12)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !recent.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(recent, id: \.self) { c in
                            Button { command = c } label: { Text(c).font(.caption.monospaced()).lineLimit(1) }
                                .buttonStyle(.bordered).disabled(!tools)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Button("Run") { run(command) }.buttonStyle(.borderedProminent).disabled(!tools || running || command.trimmed.isEmpty)
                if running { ProgressView() }
            }
            if let output {
                ScrollView {
                    Text(output).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(maxHeight: 320)
                .background(outputFailed ? Color.red.opacity(0.12) : Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        Panel {
            Text("Install an APK").font(.subheadline.bold())
            Text("Pick an .apk in Files: it's installed on \(tvLabel) (an update keeps the app's data).")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Choose an APK") { pickingApk = true }.buttonStyle(.borderedProminent).disabled(!tools || installing)
                if installing { ProgressView() }
            }
            if let installNote { Text(installNote).font(.subheadline).foregroundStyle(installFailed ? .red : .primary) }
        }
    }

    private func run(_ cmd: String) {
        let c = cmd.trimmed
        guard !c.isEmpty, !running else { return }
        running = true
        output = nil
        Task {
            defer {
                running = false
                recent = SettingsView.rememberCommand(c)
            }
            do {
                let r = try await TvLink.shell(host, c)
                outputFailed = r.exitCode != 0
                let all = r.allOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                output = (all.isEmpty ? "(no output, exit \(r.exitCode))" : all) + (r.exitCode != 0 && !all.isEmpty ? "\n(exit \(r.exitCode))" : "")
                log.add("Command: \(c)", via: Via.adb, ok: r.exitCode == 0)
            } catch {
                outputFailed = true
                output = "Couldn't reach \(tvLabel): \(error.localizedDescription)"
                log.add("Command: \(c)", via: Via.adb, ok: false)
            }
        }
    }

    private func install(_ url: URL) {
        let name = url.lastPathComponent
        installing = true
        installFailed = false
        installNote = "Installing \(name) on \(tvLabel)…"
        Task {
            defer { installing = false }
            // A file from Files is lent while it's read: a copy, then the TV gets it.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("install.apk")
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try? FileManager.default.removeItem(at: copy)
                try FileManager.default.copyItem(at: url, to: copy)
                try await TvLink.install(host, apk: copy)
                installNote = "Installed \(name) on \(tvLabel)."
                log.add("Installed \(name)", via: Via.adb)
            } catch {
                installFailed = true
                installNote = "Couldn't install \(name): \(error.localizedDescription)"
                log.add("Install \(name)", via: Via.adb, ok: false)
            }
            try? FileManager.default.removeItem(at: copy)
        }
    }

    static func recentCommands() -> [String] {
        (UserDefaults.standard.string(forKey: "settings.recentCommands") ?? "").split(separator: "\n").map(String.init).filter { !$0.trimmed.isEmpty }
    }

    /** The last 8 commands run, newest first. */
    static func rememberCommand(_ c: String) -> [String] {
        let list = Array(([c] + recentCommands().filter { $0 != c }).prefix(8))
        UserDefaults.standard.set(list.joined(separator: "\n"), forKey: "settings.recentCommands")
        return list
    }

    // MARK: Privacy and About

    @ViewBuilder private var privacy: some View {
        SectionHeader("Privacy")
        Panel {
            Text("Skiff for iPhone sends no crash reports or usage. Your TVs, history and keys stay on this phone.")
                .font(.subheadline)
        }
    }

    @ViewBuilder private var about: some View {
        SectionHeader("About")
        Button {
            if let u = updates.update {
                openURL(URL(string: u.pageUrl)!)
            } else if !checking {
                checking = true
                checkNote = nil
                Task {
                    do {
                        if try await updates.check(force: true) == nil { checkNote = "You have the latest version." }
                    } catch {
                        checkNote = "Couldn't check: \(error.localizedDescription)"
                    }
                    checking = false
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(updates.update.map { "Update to \($0.version)" } ?? "Check for updates").font(.headline).foregroundStyle(.primary)
                    Text(updates.update != nil ? "You have \(Updates.current). Get the new .ipa on GitHub"
                         : checking ? "Checking…" : checkNote ?? "Version \(Updates.current)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if checking { ProgressView() } else if updates.update != nil { Image(systemName: "arrow.up.right.square") }
            }
            .padding(16)
            .background(updates.update != nil ? Color.accentColor.opacity(0.18) : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
        LinkRow(title: "Report an issue", subtitle: "On GitHub, with Skiff's version and your phone's model filled in") { openURL(issueUrl) }
        LinkRow(title: "Privacy policy", subtitle: "What Skiff keeps on your phone, and what it sends") {
            openURL(URL(string: "https://github.com/yogeshpaliyal/skiff/blob/main/PRIVACY.md")!)
        }
    }

    /** A new GitHub issue, its body started: Skiff's version, iOS version, phone model. Nothing about your TVs or history. */
    private var issueUrl: URL {
        let body = "**What happened**\n\n\n**What you expected**\n\n\n**Steps to see it**\n1. \n\n---\n" +
            "Skiff \(Updates.current) (\(Updates.build)) for iOS, iOS \(UIDevice.current.systemVersion), \(Self.modelName)"
        var c = URLComponents(string: "https://github.com/yogeshpaliyal/skiff/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        return c.url!
    }

    /** "iPhone15,2". */
    static var modelName: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/** A line of the connection's state: `good` true (green), false (red), nil (neutral). */
struct StatusRow<Action: View>: View {
    let label: String
    let value: String
    let good: Bool?
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(good == true ? Brand.green : good == false ? Color.red : Color.gray).frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(label).font(.subheadline.bold())
                Text(value).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            action
        }
    }
}

extension StatusRow where Action == EmptyView {
    init(label: String, value: String, good: Bool?) { self.init(label: label, value: value, good: good) { EmptyView() } }
}

/** A row that opens something: title, a line about it, and a chevron. */
struct LinkRow: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/** What Skiff sent to the TV, and how: newest first. (ActivityScreen.kt) */
struct ActivityView: View {
    @State private var log = ActivityLog.shared

    var body: some View {
        List {
            if log.entries.isEmpty {
                Text("What Skiff sends to the TV shows here, with how it went: Pairing or USB debugging.")
                    .foregroundStyle(.secondary)
            }
            ForEach(log.entries) { e in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(e.ok ? Brand.green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.what)
                        Text([e.via, relativeTime(e.t), e.ok ? nil : "failed"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !log.entries.isEmpty { Button("Clear") { log.clear() } }
            }
        }
    }
}
