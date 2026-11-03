import Foundation
import Security
import UIKit

/**
 * The Android TV Remote protocol (v2): what the Google TV phone app speaks, served by every Google TV's "Android TV
 * Remote Service". No developer options: the phone pairs once with a code the TV shows, then controls it over TLS.
 *  - pairing, port 6467: `pair`;
 *  - the remote, port 6466: `connect` — keys, text, and app links (a link opened on the TV, in the app for it).
 * The TV's certificate is self-signed: it's pinned at pairing (its SHA-256) and checked on every connection. (atv/Atv.kt)
 */
enum Atv {
    static let pairingPort: UInt16 = 6467
    static let remotePort: UInt16 = 6466

    private static var defaults: UserDefaults { .standard }
    private static func key(_ host: String) -> String { "atv.paired:" + host.trimmed }
    private static func nameKey(_ name: String) -> String { "atv.pairedName:" + name.trimmed.lowercased() }

    // MARK: Pairing

    /** A pairing in progress: the TV shows a 6-character code; `finish` with it. */
    final class Pairing {
        enum Result { case paired, mistyped, refused }

        private let host: String
        private let socket: Socket
        private let client: Messages.RsaKey

        fileprivate init(host: String, socket: Socket, client: Messages.RsaKey) {
            self.host = host
            self.socket = socket
            self.client = client
        }

        /**
         * MISTYPED: the code doesn't match these certificates (checked here, nothing sent: type it again). REFUSED:
         * the TV said no, and this pairing is over (start again).
         */
        func finish(_ code: String) async -> Result {
            guard let server = socket.peerCertificate, let serverKey = Identity.rsaNumbers(certificate: server),
                  let secret = Messages.pairingSecret(client: client, server: serverKey, code: code) else { return .mistyped }
            let reply: Messages.Outer? = try? await socket.deadline(10) {
                try await socket.writeFrame(Messages.secret(secret))
                return try Messages.Outer(try await socket.readFrame())
            }
            close()
            guard let reply, reply.status == 200, reply.isSecretAck else { return .refused }
            Atv.defaults.set(Socket.fingerprint(server), forKey: Atv.key(host))
            return .paired
        }

        func close() { socket.close() }
    }

    /** Starts pairing: the TV shows a code (and "Skiff on iPhone" as the device). Returns once it does. */
    static func pair(_ host: String) async throws -> Pairing {
        let (identity, certificate) = try Identity.atvIdentity()
        guard let pub = SecCertificateCopyKey(certificate), let pkcs1 = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
              let client = Identity.rsaNumbers(pkcs1: pkcs1) else { throw TvError.other("Couldn't read this phone's certificate") }
        let socket = Socket(host: host, port: pairingPort, tls: .init(identity: identity, pinned: nil))
        try await socket.connect(timeout: 10)
        do {
            let device = await MainActor.run { UIDevice.current.model }
            try await socket.writeFrame(Messages.pairingRequest("Skiff on \(device)"))
            while true {
                let m = try await socket.deadline(10, TvError.timeout("The TV didn't show a code in time. Try again; check it's on.")) {
                    try Messages.Outer(try await socket.readFrame())
                }
                if m.status != 200 { throw TvError.other("The TV refused pairing (status \(m.status)).") }
                if m.isPairingRequestAck {
                    try await socket.writeFrame(Messages.options())
                } else if m.isOptions {
                    try await socket.writeFrame(Messages.configuration())
                } else if m.isConfigurationAck {
                    return Pairing(host: host, socket: socket, client: client)    // the code is on screen
                } else {
                    throw TvError.other("Unexpected message while pairing.")
                }
            }
        } catch {
            socket.close()
            throw error
        }
    }

    /** This phone paired with that TV (at that address) before. */
    static func isPaired(_ host: String) -> Bool { defaults.string(forKey: key(host)) != nil }

    /** Forget a TV, at this address and by its name. */
    static func forget(_ host: String, name: String = "") {
        let fp = defaults.string(forKey: key(host))
        defaults.removeObject(forKey: key(host))
        if !name.trimmed.isEmpty { defaults.removeObject(forKey: nameKey(name)) }
        // Its other addresses too: the same TV (the same certificate).
        if let fp {
            for (k, v) in defaults.dictionaryRepresentation() where k.hasPrefix("atv.paired") && (v as? String) == fp {
                defaults.removeObject(forKey: k)
            }
        }
    }

    /** Keeps the pairing by the TV's name too, so a new address finds it again (`adopt`). */
    static func rememberName(_ host: String, name: String) {
        guard !name.trimmed.isEmpty, let fp = defaults.string(forKey: key(host)) else { return }
        if defaults.string(forKey: nameKey(name)) != fp { defaults.set(fp, forKey: nameKey(name)) }
    }

    /** A TV found at `host` under `name`, paired before at another address: the pairing carries over. */
    @discardableResult
    static func adopt(_ host: String, name: String) -> Bool {
        guard !name.trimmed.isEmpty, defaults.string(forKey: key(host)) == nil,
              let fp = defaults.string(forKey: nameKey(name)) else { return false }
        defaults.set(fp, forKey: key(host))
        return true
    }

    // MARK: The remote

    /** The TV refused the phone: not paired (or the TV forgot it). */
    struct NotPaired: LocalizedError { let message: String; var errorDescription: String? { message } }

    /** A connected remote: keys, text, links; the TV's pings are answered in the background. Close it when done. */
    final class Remote: TvKeys, @unchecked Sendable {
        private let socket: Socket
        private let lock = NSLock()
        private var imeCounter = 0
        private var fieldCounter = 0
        private var imeReady = false
        private var focusIme: Int?
        private var focusField: Int?
        private var _field: String?
        private var features = Messages.features
        private var started: CheckedContinuation<Void, Error>?
        private var didStart = false
        private var reader: Task<Void, Never>?
        private let order = AsyncMutex()

        var onField: ((String?) -> Void)?
        var field: String? { lock.withLock { _field } }
        var isOpen: Bool { !socket.isClosed }

        fileprivate init(socket: Socket) { self.socket = socket }

        private func setField(_ v: String?) {
            lock.withLock { _field = v }
            let cb = onField
            Task { @MainActor in cb?(v) }
        }

        fileprivate func start() {
            reader = Task.detached { [weak self] in
                guard let self else { return }
                do {
                    while true {
                        let m = try Messages.Remote(try await self.socket.readFrame())
                        if let c = m.configure {
                            let f = Messages.features & c.int(1)
                            self.lock.withLock { self.features = f }
                            try await self.send(Messages.remoteConfigure(f))
                        } else if m.setActive {
                            try await self.send(Messages.remoteSetActive(self.lock.withLock { self.features }))
                        } else if let p = m.pingVal1 {
                            try await self.send(Messages.pingResponse(p))
                        } else if let edit = m.imeBatchEdit {
                            self.lock.withLock {
                                self.imeCounter = edit.int(1)
                                self.fieldCounter = edit.int(2)
                                self.imeReady = true
                            }
                            self.setField(m.imeFieldText ?? self.field ?? "")
                        } else if let counter = m.imeFieldCounter {
                            self.lock.withLock {
                                self.focusField = counter
                                if let a = m.imeAppCounter { self.focusIme = a }
                                self.imeReady = true
                            }
                            self.setField(m.imeFieldText ?? "")
                        } else if m.start != nil {
                            self.resumeStarted(nil)
                        }
                    }
                } catch {
                    self.resumeStarted(error)
                    self.close()
                }
            }
        }

        private func resumeStarted(_ error: Error?) {
            let c: CheckedContinuation<Void, Error>? = lock.withLock {
                didStart = true
                let w = started
                started = nil
                return w
            }
            if let error { c?.resume(throwing: error) } else { c?.resume() }
        }

        fileprivate func awaitStarted() async throws {
            try await socket.deadline(8, TvError.timeout("The TV connected but didn't start the remote. Wake it up, then try again.")) {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    let already: Bool = lock.withLock {
                        if didStart { return true }
                        started = c
                        return false
                    }
                    if already { c.resume() }
                }
            }
        }

        private func send(_ message: Data) async throws { try await socket.writeFrame(message) }

        /** A key (Android's key codes: the protocol uses them). */
        func key(_ code: Int) async throws {
            try await order.withLock { try await send(Messages.keyInject(code)) }
        }

        /**
         * Text into the TV's focused field. When the TV has sent its input method's counters for the field, as an edit
         * of that field (the way the Google TV app types); otherwise as key presses (Shift held for capitals).
         */
        func text(_ s: String) async throws {
            let ready = lock.withLock { imeReady }
            if s.isEmpty && !ready { return }
            let keys = s.map(Key.forCharacter)
            if ready || keys.contains(where: { $0 == nil }) {
                try await order.withLock { try await edit(s) }
                return
            }
            try await order.withLock {
                for k in keys.compactMap({ $0 }) {
                    if k.shift { try await send(Messages.keyInject(Key.shiftLeft, direction: Messages.directionDown)) }
                    try await send(Messages.keyInject(k.code))
                    if k.shift { try await send(Messages.keyInject(Key.shiftLeft, direction: Messages.directionUp)) }
                }
            }
        }

        /** The pairs of counters to send an edit with: the focused field's first, then the batch edit's. */
        private func counterPairs() -> [(Int, Int)] {
            lock.withLock {
                var out: [(Int, Int)] = []
                if let i = focusIme, let f = focusField { out.append((i, f)) }
                if !out.contains(where: { $0 == (imeCounter, fieldCounter) }) { out.append((imeCounter, fieldCounter)) }
                return out
            }
        }

        private func sendEdit(_ text: String, insert: Int = 1) async throws {
            for (ime, field) in counterPairs() { try await send(Messages.imeText(ime: ime, field: field, text: text, insert: insert)) }
        }

        /** Waits (a little) for the TV to say its field reads `text`: it answers each edit it takes. */
        private func tvShows(_ text: String) async -> Bool {
            for _ in 0..<14 {
                if field == text { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return field == text
        }

        /**
         * Makes the TV's field read `target`. The TV takes an edit when the text grows, but not when it shrinks: then
         * the same edit with insert off is tried, and if the field still reads the old text, Delete is pressed for what
         * has to go, and the rest is added.
         */
        private func edit(_ target: String) async throws {
            let now = field ?? ""
            if target == now { return }
            if target.hasPrefix(now) {
                try await sendEdit(target)
                return
            }
            try await sendEdit(target, insert: 0)
            if await tvShows(target) { return }
            let keep = now.commonPrefix(with: target).count
            let current = field ?? now
            for _ in 0..<max(current.count - keep, 0) { try await send(Messages.keyInject(Key.del)) }
            if target.count > keep {
                _ = await tvShows(String(target.prefix(keep)))
                try await sendEdit(target)
            }
        }

        /** Opens a link on the TV (an app's own link, a web link…), in the app the TV picks for it. */
        func openLink(_ link: String) async throws { try await send(Messages.appLink(link)) }

        func close() {
            socket.close()
            reader?.cancel()
            resumeStarted(TvError.closed())
        }
    }

    /** A connected, started remote. Throws `NotPaired` when the TV refuses the phone (pair first). */
    static func connect(_ host: String) async throws -> Remote {
        guard let pinned = defaults.string(forKey: key(host)) else { throw NotPaired(message: "Not paired with this TV yet.") }
        let (identity, _) = try Identity.atvIdentity()
        let socket = Socket(host: host, port: remotePort, tls: .init(identity: identity, pinned: pinned))
        do {
            try await socket.connect(timeout: 10)
        } catch let e as TvError where e.kind == .timeout {
            throw TvError.timeout("The TV didn't answer. Check it's on (not asleep), and on the same network as this phone.")
        } catch let e as TvError where e.kind == .refused {
            throw TvError.other("Couldn't reach the TV's remote service. Check it's on, and on the same network as this phone.")
        } catch {
            throw NotPaired(message: "The TV didn't accept this phone: pair again. (\(error.localizedDescription))")
        }
        let remote = Remote(socket: socket)
        remote.start()
        do {
            try await remote.awaitStarted()
        } catch let e as TvError where e.kind == .timeout {
            remote.close()
            throw e
        } catch {
            remote.close()
            throw NotPaired(message: "The TV didn't start the remote: pair again. (\(error.localizedDescription))")
        }
        return remote
    }

    /** Connects, opens a link on the TV (the TV picks the app), and disconnects. */
    static func openLink(_ host: String, _ link: String) async throws {
        let remote = try await connect(host)
        defer { remote.close() }
        try await remote.openLink(link)
        try? await Task.sleep(nanoseconds: 300_000_000)     // let the TV read it before the connection closes
    }
}
