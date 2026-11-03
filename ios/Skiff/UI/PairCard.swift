import SwiftUI

/**
 * Pairing with a TV (the Google TV remote protocol: no developer options): the TV shows a code, typed here. On the
 * main screen (the first time), in the remote, and in Settings. (PairCard.kt)
 */
struct PairCard<Footer: View>: View {
    let host: String
    var title = "Pair with this TV"
    var intro = "Like the Google TV app: the TV shows a code, you type it here. No developer options or USB debugging."
    var onPaired: () -> Void
    var onCancel: (() -> Void)? = nil
    @ViewBuilder var footer: Footer

    @State private var pairing: Atv.Pairing?
    @State private var busy = false
    @State private var note: String?
    @State private var code = ""

    var body: some View {
        Panel(tint: Color.accentColor.opacity(0.12)) {
            Text(title).font(.headline)
            Text(pairing == nil ? intro : "Type the code shown on the TV.").font(.subheadline)
            if pairing != nil {
                TextField("Code on the TV", text: Binding(get: { code }, set: { v in
                    code = String(v.uppercased().filter { "0123456789ABCDEF".contains($0) }.prefix(6))
                }))
                .font(.title2.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { if code.count == 6 { finish() } }
                .padding(12)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let note { Text(note).font(.subheadline).foregroundStyle(.red) }
            HStack(spacing: 12) {
                if pairing == nil {
                    Button("Show a code on the TV") { start() }.buttonStyle(.borderedProminent).disabled(busy || host.isEmpty)
                    if let onCancel { Button("Cancel", action: onCancel) }
                } else {
                    Button("Pair") { finish() }.buttonStyle(.borderedProminent).disabled(busy || code.count != 6)
                    Button("Cancel") { pairing?.close(); pairing = nil; onCancel?() }
                }
                if busy { ProgressView() }
            }
            if pairing == nil { footer }
        }
        .onDisappear { pairing?.close() }
    }

    private func start() {
        busy = true
        note = nil
        Task {
            defer { busy = false }
            do {
                pairing?.close()
                pairing = try await Atv.pair(host)
                code = ""
            } catch {
                note = "Couldn't start pairing: \(error.localizedDescription)"
            }
        }
    }

    private func finish() {
        guard let p = pairing else { return }
        busy = true
        Task {
            defer { busy = false }
            switch await p.finish(code) {
            case .paired:
                pairing = nil
                note = nil
                ActivityLog.shared.add("Paired with \(host)", via: Via.pairing)
                onPaired()
            case .mistyped:
                note = "That code doesn't match: check it on the TV."
            case .refused:
                pairing = nil
                note = "The TV didn't accept it. Pair again."
            }
        }
    }
}

extension PairCard where Footer == EmptyView {
    init(host: String, onPaired: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        self.init(host: host, onPaired: onPaired, onCancel: onCancel) { EmptyView() }
    }
}
