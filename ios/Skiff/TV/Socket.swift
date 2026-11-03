import CryptoKit
import Foundation
import Network
import Security

/** Why talking to the TV failed, in words for the screen. */
struct TvError: LocalizedError {
    enum Kind { case timeout, refused, closed, tls, other }
    let kind: Kind
    let message: String
    var errorDescription: String? { message }

    static func timeout(_ m: String = "The TV didn't answer in time.") -> TvError { TvError(kind: .timeout, message: m) }
    static func closed(_ m: String = "The TV closed the connection.") -> TvError { TvError(kind: .closed, message: m) }
    static func other(_ m: String) -> TvError { TvError(kind: .other, message: m) }
}

/**
 * A TCP connection to the TV (Network.framework), with TLS when `tls` is given: our client identity, and the TV's
 * self-signed certificate accepted (`pinned`: only the one with this SHA-256). Reads are made by one reader at a
 * time; writes keep the order they're made in (one send per message).
 */
final class Socket: @unchecked Sendable {
    struct Tls {
        var identity: SecIdentity
        /** The SHA-256 (hex) the TV's certificate must have; nil: any (pairing). */
        var pinned: String?
    }

    private let conn: NWConnection
    private let queue = DispatchQueue(label: "dev.skiff.socket")
    private var buffer = Data()
    private let lock = NSLock()
    private var _peer: SecCertificate?
    private var _closed = false
    private var connectWaiter: CheckedContinuation<Void, Error>?

    /** The TV's certificate, once the TLS handshake is done. */
    var peerCertificate: SecCertificate? { lock.withLock { _peer } }
    var isClosed: Bool { lock.withLock { _closed } }

    init(host: String, port: UInt16, tls: Tls? = nil) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        var tlsOptions: NWProtocolTLS.Options? = nil
        if let tls {
            let o = NWProtocolTLS.Options()
            let sec = o.securityProtocolOptions
            if let id = sec_identity_create(tls.identity) {
                sec_protocol_options_set_local_identity(sec, id)
            }
            let pinned = tls.pinned
            // The TV's certificate is self-signed (no authority to check it against): any is accepted to pair with,
            // and after that only the one paired with (trust on first use, like SSH).
            sec_protocol_options_set_verify_block(sec, { [weak self] _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
                self?.lock.withLock { self?._peer = leaf }
                if let pinned {
                    complete(leaf.map { Socket.fingerprint($0) == pinned } ?? false)
                } else {
                    complete(true)
                }
            }, queue)
            tlsOptions = o
        }
        let params = NWParameters(tls: tlsOptions, tcp: tcp)
        conn = NWConnection(host: NWEndpoint.Host(host.trimmed), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    /** Connects (and shakes hands), giving up after `timeout` seconds. */
    func connect(timeout: TimeInterval = 10) async throws {
        try await deadline(timeout, TvError.timeout("The TV didn't answer. Check it's on, and on the same Wi-Fi.")) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                self.lock.withLock { self.connectWaiter = c }
                self.conn.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.resumeConnect(nil)
                    case .waiting(let e), .failed(let e): self.resumeConnect(e); self.close()
                    case .cancelled: self.resumeConnect(TvError.closed())
                    default: break
                    }
                }
                self.conn.start(queue: self.queue)
            }
        }
    }

    private func resumeConnect(_ error: Error?) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            let w = connectWaiter
            connectWaiter = nil
            return w
        }
        if let error { c?.resume(throwing: Socket.describe(error)) } else { c?.resume() }
    }

    /** A Network error in words: refused (nothing listens there), TLS (the TV didn't accept us), or as it is. */
    static func describe(_ e: Error) -> Error {
        guard let nw = e as? NWError else { return e }
        switch nw {
        case .posix(let code) where code == .ECONNREFUSED: return TvError(kind: .refused, message: "Nothing answers on that port (connection refused).")
        case .posix(let code) where code == .ETIMEDOUT: return TvError.timeout()
        case .tls(let status): return TvError(kind: .tls, message: "TLS error \(status)")
        default: return TvError.other(nw.localizedDescription)
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: Socket.describe(error)) } else { c.resume() }
            })
        }
    }

    /** More bytes into the buffer (at least one). */
    private func fill() async throws {
        let more: Data = try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let error { c.resume(throwing: Socket.describe(error)); return }
                if let data, !data.isEmpty { c.resume(returning: data); return }
                if complete { c.resume(throwing: TvError.closed()); return }
                c.resume(returning: Data())
            }
        }
        buffer.append(more)
    }

    /** Exactly `n` bytes. */
    func read(_ n: Int) async throws -> Data {
        while buffer.count < n { try await fill() }
        let out = buffer.prefix(n)
        buffer = Data(buffer.dropFirst(n))
        return Data(out)
    }

    func readByte() async throws -> UInt8 { try await read(1)[0] }

    /** One varint-framed message (the remote protocol's framing). */
    func readFrame() async throws -> Data {
        var shift = 0
        var len = 0
        while true {
            let b = try await readByte()
            len |= Int(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            if shift > 35 { throw ProtoError.malformed("frame length too long") }
        }
        if len > 1_000_000 { throw ProtoError.malformed("frame too big: \(len)") }
        return try await read(len)
    }

    func writeFrame(_ message: Data) async throws { try await write(ProtoWriter.frame(message)) }

    func close() {
        let already: Bool = lock.withLock {
            let was = _closed
            _closed = true
            return was
        }
        if !already { conn.cancel() }
    }

    /**
     * Runs `op`, closing the connection when it takes longer than `seconds` (a read that never returns fails then):
     * it throws `timeoutError` instead of the read's error.
     */
    func deadline<T>(_ seconds: TimeInterval, _ timeoutError: Error = TvError.timeout(), _ op: () async throws -> T) async throws -> T {
        let fired = Flag()
        let work = DispatchWorkItem { [weak self] in
            fired.set()
            self?.close()
            self?.resumeConnect(timeoutError)
        }
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
        defer { work.cancel() }
        do {
            return try await op()
        } catch {
            if fired.isSet { throw timeoutError }
            throw error
        }
    }

    /** A certificate's SHA-256, in hex (what's pinned). */
    static func fingerprint(_ cert: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
    }
}

/** A flag set once, from any thread. */
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/** A lock for async code: one holder at a time, the others wait their turn (in order). */
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    nonisolated func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await lock()
        do {
            let r = try await body()
            await unlock()
            return r
        } catch {
            await unlock()
            throw error
        }
    }
}
