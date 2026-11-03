import SwiftUI
import UIKit

/** The remote's connection and what it sends: one connection while it's showing. (RemoteScreen.kt) */
@MainActor @Observable
final class RemoteModel {
    let host: String
    let tvName: String
    let mode: Connection.Mode
    var remote: TvKeys?
    var via = ""        // "Pairing" or "USB debugging"
    var error: String?
    var attempt = 0
    var typing = false
    var typed = ""
    var tvField: String?
    var cursor = false
    var air = AirCursor.available
    var cursorError: String?
    @ObservationIgnored private var editedAt = Date.distantPast
    @ObservationIgnored private var waiting: [Int] = []
    @ObservationIgnored let motion = Motion()
    @ObservationIgnored private let airCursor = AirCursor()
    @ObservationIgnored private let volume = VolumeButtons()
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var pointerTask: Task<Void, Never>?
    @ObservationIgnored private var typeTask: Task<Void, Never>?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(host: String, tvName: String) {
        self.host = host
        self.tvName = tvName
        mode = Connection.remote(host)
    }

    var ready: Bool { remote != nil }
    var canCursor: Bool { remote?.hasCursor == true }
    var pointing: Bool { cursor && canCursor }
    var live: Bool { tvField != nil }
    var name: String { tvName.isEmpty ? "the TV" : tvName }

    /**
     * Connected while the remote is showing, as Settings says: Automatic is USB debugging when this phone is allowed
     * there, else paired, else USB debugging anyway (the TV asks to allow this phone), else: pair.
     */
    func connect() {
        connectTask?.cancel()
        error = nil
        remote?.close()
        setRemote(nil)
        if host.isEmpty {
            error = "Pick a TV first."
            return
        }
        let host = host, name = name, mode = mode
        connectTask = Task {
            func viaAdb() async -> Bool {
                do {
                    let r = try await TvLink.remote(host)
                    if Task.isCancelled { r.close(); return true }
                    via = Via.adb
                    setRemote(r)
                    ActivityLog.shared.add("Remote connected", via: via)
                    return true
                } catch {
                    self.error = "Couldn't reach \(name) over USB debugging: \(error.localizedDescription)"
                    return false
                }
            }
            func viaPairing() async -> Bool {
                do {
                    let r = try await Atv.connect(host)
                    if Task.isCancelled { r.close(); return true }
                    via = Via.pairing
                    setRemote(r)
                    ActivityLog.shared.add("Remote connected", via: via)
                    return true
                } catch {
                    self.error = error.localizedDescription
                    return false
                }
            }
            let paired = Atv.isPaired(host)
            switch mode {
            case .adb: _ = await viaAdb()
            case .pairing:
                if paired { _ = await viaPairing() } else { error = "Pair with \(name) to use the remote (Settings: Pairing only)." }
            case .auto:
                let adb = await TvLink.check(host)
                if adb == .allowed {
                    if await viaAdb() { break }
                    if paired { _ = await viaPairing() }
                } else if paired {
                    _ = await viaPairing()
                } else if adb == .off {
                    // USB debugging off (a Google TV Streamer, most TVs): nothing to try but pairing.
                    error = "Pair with \(name) to use the remote: no USB debugging needed."
                } else if !(await viaAdb()) {
                    error = "Pair with \(name) to use the remote: no USB debugging needed."
                }
            }
        }
    }

    private func setRemote(_ r: TvKeys?) {
        remote = r
        tvField = r?.field
        r?.onField = { [weak self] v in self?.fieldChanged(v) }
        if r != nil {
            volume.start { [weak self] code in self?.press(code) }
            sendWaiting()
        } else {
            volume.stop()
        }
        updatePointer()
    }

    /** The TV's text, when you aren't mid-typing (an echo of an older edit mustn't undo newer letters). */
    private func fieldChanged(_ v: String?) {
        tvField = v
        if let v, Date().timeIntervalSince(editedAt) > 1.5, v != typed { typed = v }
    }

    /** Connected (again): the keys pressed meanwhile go now. */
    private func sendWaiting() {
        guard let r = remote, !waiting.isEmpty else { return }
        let keys = waiting
        waiting = []
        let via = via
        Task {
            for code in keys {
                do {
                    try await r.key(code)
                    ActivityLog.shared.add("Key \(Key.name(code)) (after reconnecting)", via: via)
                } catch {
                    ActivityLog.shared.add("Key \(Key.name(code))", via: via, ok: false)
                }
            }
        }
    }

    /** Reconnects, the key kept to send once connected (the TV may have closed this remote for another phone's). */
    func reconnect(_ code: Int?) {
        if let code, waiting.count < 8 { waiting.append(code) }
        if remote != nil {
            attempt += 1
            connect()
        }
    }

    /** Back in the foreground: reconnect if the TV closed this remote meanwhile. */
    func resumed() {
        if let r = remote, !r.isOpen { reconnect(nil) }
    }

    /** A key now. A closed connection reconnects first, and the key goes once it's back. */
    func press(_ code: Int) {
        haptic.impactOccurred()
        guard let r = remote else {
            if attempt > 0 && error == nil && waiting.count < 8 { waiting.append(code) }
            return
        }
        if !r.isOpen { return reconnect(code) }
        let via = via
        Task {
            do {
                try await r.key(code)
                ActivityLog.shared.add("Key \(Key.name(code))", via: via)
            } catch {
                reconnect(code)
            }
        }
    }

    /** Over pairing with a field focused, every change replaces the TV's text, a moment after you stop typing. */
    func typedChanged() {
        editedAt = Date()
        guard live, let r = remote, typed != tvField else { return }
        typeTask?.cancel()
        let t = typed
        typeTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            try? await r.text(t)
        }
    }

    /** Send: types it in. */
    func type() {
        let t = typed
        guard let r = remote, !t.isEmpty else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let via = via
        Task {
            do {
                try await r.text(t)
                typed = ""
                ActivityLog.shared.add("Typed “\(t)”", via: via)
            } catch {
                ActivityLog.shared.add("Typed “\(t)”", via: via, ok: false)
            }
        }
    }

    // MARK: The pointer

    func toggleCursor() {
        cursor.toggle()
        updatePointer()
    }

    func toggleAir() {
        air.toggle()
        updatePointer()
    }

    /** The pointer's moves go one report at a time, what gathered meanwhile in the next: the TV never falls behind. */
    private func updatePointer() {
        pointerTask?.cancel()
        pointerTask = nil
        airCursor.stop()
        motion.clear()
        guard pointing, let r = remote else { return }
        cursorError = nil
        if air { airCursor.start { [weak self] dx, dy in self?.motion.move(dx, dy) } }
        pointerTask = Task {
            while !Task.isCancelled {
                let (dx, dy, wheel) = motion.take()
                if dx != 0 || dy != 0 || wheel != 0 {
                    do {
                        try await r.mouse(dx: dx, dy: dy, buttons: 0, wheel: wheel)
                    } catch {
                        if !r.isOpen { reconnect(nil); return }
                        cursorError = "The TV didn't take the cursor: \(error.localizedDescription)"
                        cursor = false
                        updatePointer()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    func click() {
        guard let r = remote else { return }
        haptic.impactOccurred()
        Task {
            try? await r.mouse(dx: 0, dy: 0, buttons: MouseButton.left, wheel: 0)
            try? await r.mouse(dx: 0, dy: 0, buttons: 0, wheel: 0)
        }
    }

    func close() {
        connectTask?.cancel()
        pointerTask?.cancel()
        airCursor.stop()
        volume.stop()
        remote?.close()
        remote = nil
    }
}

/**
 * A remote for the TV, laid out like a physical one, by importance: the D-pad and OK first and biggest; then Home
 * (bigger) between Back and Menu; then two capsules, a volume rocker and playback. Arrows, volume and seek repeat when
 * held. Power sits apart, in red. (RemoteScreen.kt)
 */
struct RemoteView: View {
    @State private var model: RemoteModel
    @State private var paired: Bool
    @Environment(\.scenePhase) private var scenePhase
    let onBack: () -> Void

    init(host: String, tvName: String, onBack: @escaping () -> Void) {
        _model = State(initialValue: RemoteModel(host: host, tvName: tvName))
        _paired = State(initialValue: Atv.isPaired(host))
        self.onBack = onBack
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if let e = model.error {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Text(e).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            Button { model.attempt += 1; model.connect() } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        }
                        .padding(16)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                    if !model.ready && model.error == nil {
                        HStack(spacing: 12) { ProgressView(); Text("Connecting…").font(.subheadline) }
                    }
                    // Pairing: when there's no connection, or (not paired yet) to stop needing USB debugging.
                    if model.mode != .adb && (model.error != nil || (model.via == Via.adb && !paired)) {
                        PairCard(host: model.host, onPaired: { paired = true; model.attempt += 1; model.connect() })
                    }

                    if model.pointing {
                        Touchpad(enabled: model.ready, air: model.air, onMove: { model.motion.move($0, $1) },
                                 onWheel: { model.motion.turn($0) }, onClick: { model.click() })
                    } else {
                        DPad(enabled: model.ready) { model.press($0) }
                    }
                    if model.canCursor || model.via == Via.pairing {
                        VStack(spacing: 6) {
                            HStack(spacing: 8) {
                                Toggle(isOn: Binding(get: { model.pointing }, set: { _ in model.toggleCursor() })) {
                                    Label("Cursor", systemImage: "cursorarrow")
                                }
                                .toggleStyle(.button)
                                .disabled(!model.canCursor)
                                if model.pointing && AirCursor.available {
                                    Toggle("Air: move the phone", isOn: Binding(get: { model.air }, set: { _ in model.toggleAir() }))
                                        .toggleStyle(.button)
                                }
                            }
                            if let note = !model.canCursor ? "The cursor needs USB debugging: the pairing protocol has no pointer." : model.cursorError {
                                Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                        }
                    }

                    // Navigation: Home biggest, Back and Menu either side.
                    HStack(alignment: .bottom) {
                        Spacer()
                        RoundKey(symbol: "arrow.uturn.backward", label: "Back", size: 60, enabled: model.ready, tone: .secondary) { model.press(Key.back) }
                        Spacer()
                        RoundKey(symbol: "house.fill", label: "Home", size: 76, enabled: model.ready, tone: .primary) { model.press(Key.home) }
                        Spacer()
                        RoundKey(symbol: "line.3.horizontal", label: "Menu", size: 60, enabled: model.ready, tone: .secondary) { model.press(Key.menu) }
                        Spacer()
                    }
                    .frame(maxWidth: 360)

                    // Volume rocker and playback, as two capsules.
                    HStack(spacing: 14) {
                        Capsules(label: "Volume") {
                            PressKey(symbol: "speaker.minus.fill", label: "Volume down", enabled: model.ready, repeats: true) { model.press(Key.volumeDown) }
                            PressKey(symbol: "speaker.slash.fill", label: "Mute", enabled: model.ready, small: true) { model.press(Key.volumeMute) }
                            PressKey(symbol: "speaker.plus.fill", label: "Volume up", enabled: model.ready, repeats: true) { model.press(Key.volumeUp) }
                        }
                        Capsules(label: "Playback") {
                            PressKey(symbol: "backward.fill", label: "Rewind", enabled: model.ready, repeats: true, small: true) { model.press(Key.mediaRewind) }
                            PressKey(symbol: "playpause.fill", label: "Play / pause", enabled: model.ready, filled: true) { model.press(Key.mediaPlayPause) }
                            PressKey(symbol: "forward.fill", label: "Forward", enabled: model.ready, repeats: true, small: true) { model.press(Key.mediaFastForward) }
                        }
                    }

                    // Typing into the TV, only when wanted.
                    if !model.typing {
                        Button { model.typing = true } label: { Label("Type on the TV", systemImage: "keyboard") }
                            .buttonStyle(.bordered).disabled(!model.ready)
                    } else {
                        typingField
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) { Image(systemName: "chevron.backward") }.accessibilityLabel("Back to Skiff")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 2) {
                        Text(model.tvName.isEmpty ? "Remote" : model.tvName).font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(model.error != nil ? Color.red : model.ready ? Brand.green : Color.gray).frame(width: 8, height: 8)
                            Text(model.error != nil ? "Not connected" : model.ready ? "Connected · \(model.via)" : "Connecting…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Sleep / wake (KEYCODE_POWER toggles it on Android TV): apart, and red.
                    Button { model.press(Key.power) } label: { Image(systemName: "power") }
                        .buttonStyle(.borderedProminent).tint(.red).buttonBorderShape(.circle)
                        .disabled(!model.ready)
                        .accessibilityLabel("Power")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { model.connect() }
        .onDisappear { model.close() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.resumed() } }
    }

    private func close() {
        model.close()
        onBack()
    }

    private var typingField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard").foregroundStyle(.secondary)
                TextField(model.live ? "Type on the TV" : "Select a search box on the TV first",
                          text: Binding(get: { model.typed }, set: { model.typed = $0; model.typedChanged() }))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(model.live ? .done : .send)
                    .onSubmit { if model.live { model.typing = false } else { model.type() } }
                if !model.live {
                    Button("Send") { model.type() }.disabled(!model.ready || model.typed.isEmpty)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            if model.live {
                Text("Synced with the TV's search box as you type").font(.footnote).foregroundStyle(.secondary).padding(.leading, 16)
            }
        }
    }
}

// MARK: Keys

enum Tone { case primary, secondary, tertiary }

/**
 * A key that acts on touch down (a remote shouldn't wait for the finger to lift), shrinks while pressed, and with
 * `repeats` keeps pressing while held: after 400 ms, then every 120 ms.
 */
struct Pressable<Content: View>: View {
    let enabled: Bool
    var repeats = false
    let onPress: () -> Void
    @ViewBuilder var content: (Bool) -> Content

    @State private var down = false
    @State private var repeater: Task<Void, Never>?

    var body: some View {
        content(down)
            .scaleEffect(down ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: down)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, !down else { return }
                        down = true
                        onPress()
                        if repeats {
                            repeater = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 400_000_000)
                                while !Task.isCancelled {
                                    onPress()
                                    try? await Task.sleep(nanoseconds: 120_000_000)
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        down = false
                        repeater?.cancel()
                        repeater = nil
                    }
            )
    }
}

/** The D-pad: one big rounded pad, chevrons at its edges, OK in the middle. Arrows repeat when held. */
struct DPad: View {
    let enabled: Bool
    let onKey: (Int) -> Void

    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.17, style: .continuous).fill(Color(.secondarySystemGroupedBackground))
                arrow("chevron.up", "Up", Key.dpadUp).frame(width: s * 0.36, height: s * 0.25).position(x: s / 2, y: s * 0.14)
                arrow("chevron.down", "Down", Key.dpadDown).frame(width: s * 0.36, height: s * 0.25).position(x: s / 2, y: s * 0.86)
                arrow("chevron.left", "Left", Key.dpadLeft).frame(width: s * 0.25, height: s * 0.36).position(x: s * 0.14, y: s / 2)
                arrow("chevron.right", "Right", Key.dpadRight).frame(width: s * 0.25, height: s * 0.36).position(x: s * 0.86, y: s / 2)
                Pressable(enabled: enabled, onPress: { onKey(Key.dpadCenter) }) { pressed in
                    Circle().fill(pressed ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(Brand.gradient))
                        .overlay(Text("OK").font(.title2.bold()).foregroundStyle(.white))
                }
                .frame(width: s * 0.38, height: s * 0.38)
                .position(x: s / 2, y: s / 2)
                .accessibilityLabel("OK")
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
    }

    private func arrow(_ symbol: String, _ label: String, _ code: Int) -> some View {
        Pressable(enabled: enabled, repeats: true, onPress: { onKey(code) }) { pressed in
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(pressed ? Color.accentColor.opacity(0.25) : Color.clear)
                .overlay(Image(systemName: symbol).font(.system(size: 32, weight: .semibold)).foregroundStyle(.secondary))
        }
        .accessibilityLabel(label)
    }
}

struct RoundKey: View {
    let symbol: String
    let label: String
    let size: CGFloat
    let enabled: Bool
    let tone: Tone
    let onPress: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Pressable(enabled: enabled, onPress: onPress) { pressed in
                Circle()
                    .fill(pressed ? Color.accentColor.opacity(0.5) : tone == .primary ? Color.accentColor.opacity(0.3) : Color.accentColor.opacity(0.15))
                    .overlay(Image(systemName: symbol).font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(Color.accentColor))
            }
            .frame(width: size, height: size)
            .accessibilityLabel(label)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/** A labeled capsule holding a row of keys (the volume rocker, playback). */
struct Capsules<Content: View>: View {
    let label: String
    @ViewBuilder var keys: Content

    var body: some View {
        VStack(spacing: 6) {
            HStack { keys }
                .frame(maxWidth: .infinity, minHeight: 68)
                .padding(.horizontal, 8)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PressKey: View {
    let symbol: String
    let label: String
    let enabled: Bool
    var repeats = false
    var small = false
    var filled = false
    let onPress: () -> Void

    var body: some View {
        Pressable(enabled: enabled, repeats: repeats, onPress: onPress) { pressed in
            Circle()
                .fill(filled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(pressed ? Color.accentColor.opacity(0.25) : Color.clear))
                .overlay(Image(systemName: symbol).font(.system(size: small ? 18 : 22, weight: .semibold))
                    .foregroundStyle(filled ? Color.white : Color.primary))
        }
        .frame(width: 50, height: 50)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }
}

/**
 * The touchpad, in the D-pad's place: drag to move the pointer, tap to click; the strip at its right edge scrolls.
 * (AirCursor.kt: Touchpad)
 */
struct Touchpad: View {
    let enabled: Bool
    let air: Bool
    let onMove: (Float, Float) -> Void
    let onWheel: (Float) -> Void
    let onClick: () -> Void
    @State private var lastDrag: CGSize = .zero
    @State private var lastScroll: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "cursorarrow.motionlines").font(.title).foregroundStyle(.secondary)
                Text(air ? "Point the phone at the TV and turn it to move the cursor. Drag here too; tap to click."
                         : "Drag to move the cursor; tap to click.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    guard enabled else { return }
                    let d = CGSize(width: v.translation.width - lastDrag.width, height: v.translation.height - lastDrag.height)
                    lastDrag = v.translation
                    onMove(Float(d.width) * 2.5, Float(d.height) * 2.5)     // counts per point
                }
                .onEnded { _ in lastDrag = .zero })
            .simultaneousGesture(TapGesture().onEnded { if enabled { onClick() } })
            // The scroll strip: drag down to see what's above, as on a touch screen.
            Capsule().fill(Color(.tertiarySystemGroupedBackground))
                .overlay(Text("Scroll").font(.caption2).foregroundStyle(.secondary))
                .frame(width: 46)
                .padding(.vertical, 18).padding(.trailing, 10)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        guard enabled else { return }
                        let dy = v.translation.height - lastScroll
                        lastScroll = v.translation.height
                        onWheel(Float(dy / 24))
                    }
                    .onEnded { _ in lastScroll = 0 })
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 56, style: .continuous))
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
    }
}
