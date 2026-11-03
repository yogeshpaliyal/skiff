import Foundation
import Security

/**
 * ADB over the network (the TV's port 5555), as `adb` speaks it from a computer: the transport's messages (CNXN,
 * AUTH, OPEN, OKAY, WRTE, CLSE), RSA auth with this phone's key (the TV asks "Allow USB debugging?" the first time),
 * and streams on top: shell commands (shell v2: output and exit code), an interactive shell (the pointer's `hid`),
 * and `exec:` (installing an APK). What the Android app gets from the dadb library.
 */
final class Adb: @unchecked Sendable {
    // Commands, as their four letters read little-endian.
    static let CNXN: UInt32 = 0x4E58_4E43
    static let AUTH: UInt32 = 0x4854_5541
    static let OPEN: UInt32 = 0x4E45_504F
    static let OKAY: UInt32 = 0x5941_4B4F
    static let CLSE: UInt32 = 0x4553_4C43
    static let WRTE: UInt32 = 0x4554_5257

    private static let version: UInt32 = 0x0100_0001
    private static let maxPayload: UInt32 = 256 * 1024
    private static let authToken: UInt32 = 1
    private static let authSignature: UInt32 = 2
    private static let authPublicKey: UInt32 = 3

    struct Message {
        var command: UInt32
        var arg0: UInt32
        var arg1: UInt32
        var payload: Data

        func encoded() -> Data {
            var out = Data(capacity: 24 + payload.count)
            for v in [command, arg0, arg1, UInt32(payload.count), payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }, command ^ 0xFFFF_FFFF] {
                withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
            }
            out.append(payload)
            return out
        }
    }

    /** A shell command's result: what it printed, and its exit code. */
    struct ShellResult {
        var output: String
        var errorOutput: String
        var exitCode: Int
        var allOutput: String { output + errorOutput }
    }

    private let socket: Socket
    private let lock = NSLock()
    private var streams: [UInt32: Stream] = [:]
    private var nextId: UInt32 = 1
    private var maxData = Int(Adb.maxPayload)
    private(set) var features: Set<String> = []
    private var reader: Task<Void, Never>?

    private init(socket: Socket) { self.socket = socket }

    var isOpen: Bool { !socket.isClosed }

    /**
     * Connects and authenticates: 5 s to reach the TV, `answer` seconds for it to accept this phone (time to allow it
     * on the TV, the first time).
     */
    static func connect(host: String, port: UInt16 = 5555, answer: TimeInterval) async throws -> Adb {
        let socket = Socket(host: host, port: port)
        try await socket.connect(timeout: 5)
        let adb = Adb(socket: socket)
        do {
            try await adb.handshake(answer: answer)
        } catch {
            socket.close()
            throw error
        }
        adb.startReader()
        return adb
    }

    private func readMessage() async throws -> Message {
        let h = try await socket.read(24)
        func u32(_ i: Int) -> UInt32 { h.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt32.self)) } }
        let length = Int(u32(12))
        if length > 16 * 1024 * 1024 { throw TvError.other("ADB: message too big") }
        let payload = length > 0 ? try await socket.read(length) : Data()
        return Message(command: u32(0), arg0: u32(4), arg1: u32(8), payload: payload)
    }

    private func send(_ m: Message) async throws { try await socket.write(m.encoded()) }

    private func handshake(answer: TimeInterval) async throws {
        try await send(Message(command: Adb.CNXN, arg0: Adb.version, arg1: Adb.maxPayload, payload: Data("host::\0".utf8)))
        let key = try Identity.adbKey()
        var sentSignature = false
        var sentKey = false
        try await socket.deadline(answer, TvError.timeout("The TV didn't allow this phone (USB debugging) in time.")) {
            while true {
                let m = try await readMessage()
                switch m.command {
                case Adb.CNXN:
                    maxData = Int(min(m.arg1, Adb.maxPayload))
                    let banner = String(decoding: m.payload, as: UTF8.self)
                    if let f = banner.range(of: "features=") {
                        features = Set(banner[f.upperBound...].prefix { $0 != ";" && $0 != "\0" }.split(separator: ",").map(String.init))
                    }
                    return
                case Adb.AUTH where m.arg0 == Adb.authToken:
                    if !sentSignature {
                        sentSignature = true
                        var error: Unmanaged<CFError>?
                        // RSA_sign(NID_sha1, token): PKCS#1 v1.5 with SHA-1's DigestInfo, over the token as the digest.
                        guard let sig = SecKeyCreateSignature(key, .rsaSignatureDigestPKCS1v15SHA1, m.payload as CFData, &error) as Data? else {
                            throw TvError.other("ADB: couldn't sign")
                        }
                        try await send(Message(command: Adb.AUTH, arg0: Adb.authSignature, arg1: 0, payload: sig))
                    } else if !sentKey {
                        // Not known: our public key, and the TV asks "Allow USB debugging?".
                        sentKey = true
                        let pub = try AdbKey.encode(pkcs1: Identity.publicKeyData(key))
                        try await send(Message(command: Adb.AUTH, arg0: Adb.authPublicKey, arg1: 0, payload: Data((pub + " skiff@iphone\0").utf8)))
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: Streams

    /** One stream (a shell, an exec): its data as it comes, and writes that wait for the TV's OKAY. */
    final class Stream: @unchecked Sendable {
        let localId: UInt32
        fileprivate var remoteId: UInt32 = 0
        private let lock = NSLock()
        private var inbox = Data()
        private var closed = false
        private var readWaiter: CheckedContinuation<Void, Never>?
        private var okayWaiter: CheckedContinuation<Bool, Never>?
        private var pendingOkay = false
        fileprivate weak var adb: Adb?

        fileprivate init(localId: UInt32) { self.localId = localId }

        fileprivate func received(_ data: Data) {
            let w: CheckedContinuation<Void, Never>? = lock.withLock {
                inbox.append(data)
                let w = readWaiter
                readWaiter = nil
                return w
            }
            w?.resume()
        }

        fileprivate func okay(remote: UInt32) {
            let w: CheckedContinuation<Bool, Never>? = lock.withLock {
                remoteId = remote
                let w = okayWaiter
                okayWaiter = nil
                if w == nil { pendingOkay = true }
                return w
            }
            w?.resume(returning: true)
        }

        fileprivate func didClose() {
            let (r, o): (CheckedContinuation<Void, Never>?, CheckedContinuation<Bool, Never>?) = lock.withLock {
                closed = true
                let r = readWaiter, o = okayWaiter
                readWaiter = nil
                okayWaiter = nil
                return (r, o)
            }
            r?.resume()
            o?.resume(returning: false)
        }

        var isClosed: Bool { lock.withLock { closed } }

        /** Waits for the TV's OKAY (the stream opened, or a write taken); false when it closed instead. */
        fileprivate func awaitOkay() async -> Bool {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let now: Bool? = lock.withLock {
                    if pendingOkay { pendingOkay = false; return true }
                    if closed { return false }
                    okayWaiter = c
                    return nil
                }
                if let now { c.resume(returning: now) }
            }
        }

        /** What has come so far (emptied), waiting for some; empty once the stream is closed and drained. */
        func read() async -> Data {
            while true {
                let got: Data? = lock.withLock {
                    if !inbox.isEmpty { let d = inbox; inbox = Data(); return d }
                    if closed { return Data() }
                    return nil
                }
                if let got { return got }
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let ready: Bool = lock.withLock {
                        if !inbox.isEmpty || closed { return true }
                        readWaiter = c
                        return false
                    }
                    if ready { c.resume() }
                }
            }
        }

        /** Everything until the TV closes the stream. */
        func readAll() async -> Data {
            var out = Data()
            while true {
                let d = await read()
                if d.isEmpty { return out }
                out.append(d)
            }
        }

        /** Data to the TV, in pieces it takes, each waiting for its OKAY. */
        func write(_ data: Data) async throws {
            guard let adb else { throw TvError.closed() }
            var rest = data[...]
            while !rest.isEmpty {
                let chunk = rest.prefix(adb.maxData)
                rest = rest.dropFirst(chunk.count)
                try await adb.send(Message(command: Adb.WRTE, arg0: localId, arg1: remoteId, payload: Data(chunk)))
                if !(await awaitOkay()) { throw TvError.closed("The TV closed the stream.") }
            }
        }

        func close() {
            guard let adb, !isClosed else { return }
            let m = Message(command: Adb.CLSE, arg0: localId, arg1: remoteId, payload: Data())
            didClose()
            Task { try? await adb.send(m) }
        }
    }

    private func startReader() {
        reader = Task.detached { [weak self] in
            guard let self else { return }
            do {
                while true {
                    let m = try await self.readMessage()
                    let stream = self.lock.withLock { self.streams[m.arg1] }
                    switch m.command {
                    case Adb.OKAY: stream?.okay(remote: m.arg0)
                    case Adb.WRTE:
                        stream?.received(m.payload)
                        try await self.send(Message(command: Adb.OKAY, arg0: m.arg1, arg1: m.arg0, payload: Data()))
                    case Adb.CLSE:
                        stream?.didClose()
                        self.lock.withLock { _ = self.streams.removeValue(forKey: m.arg1) }
                    default: break
                    }
                }
            } catch {
                self.close()
            }
        }
    }

    /** Opens a service ("shell,v2,raw:ls", "exec:cmd package install …"); throws when the TV refuses it. */
    func open(_ service: String) async throws -> Stream {
        let stream: Stream = lock.withLock {
            let s = Stream(localId: nextId)
            nextId += 1
            s.adb = self
            streams[s.localId] = s
            return s
        }
        try await send(Message(command: Adb.OPEN, arg0: stream.localId, arg1: 0, payload: Data((service + "\0").utf8)))
        guard await stream.awaitOkay() else { throw TvError.other("The TV refused \(service.before(":")).") }
        return stream
    }

    var hasShellV2: Bool { features.contains("shell_v2") }

    /** A shell command, as `adb shell` runs it: its output and exit code. */
    func shell(_ command: String) async throws -> ShellResult {
        if !hasShellV2 {
            let s = try await open("shell:" + command)
            let out = String(decoding: await s.readAll(), as: UTF8.self)
            return ShellResult(output: out, errorOutput: "", exitCode: 0)
        }
        let s = try await open("shell,v2,raw:" + command)
        let data = [UInt8](await s.readAll())
        var out = Data(), err = Data()
        var exit = 0
        var i = 0
        while i + 5 <= data.count {
            let id = data[i]
            let len = Int(data[i + 1]) | Int(data[i + 2]) << 8 | Int(data[i + 3]) << 16 | Int(data[i + 4]) << 24
            i += 5
            guard i + len <= data.count else { break }
            let body = data[i..<(i + len)]
            switch id {
            case 1: out.append(contentsOf: body)
            case 2: err.append(contentsOf: body)
            case 3: exit = Int(body.first ?? 0)
            default: break
            }
            i += len
        }
        return ShellResult(output: String(decoding: out, as: UTF8.self), errorOutput: String(decoding: err, as: UTF8.self), exitCode: exit)
    }

    /** An interactive shell: what's written goes to the command's input. */
    final class Shell {
        let stream: Stream
        let v2: Bool
        init(stream: Stream, v2: Bool) { self.stream = stream; self.v2 = v2 }

        func write(_ text: String) async throws {
            let data = Data(text.utf8)
            if !v2 { return try await stream.write(data) }
            var packet = Data([0])     // stdin
            withUnsafeBytes(of: UInt32(data.count).littleEndian) { packet.append(contentsOf: $0) }
            packet.append(data)
            try await stream.write(packet)
        }

        func close() { stream.close() }
    }

    func openShell(_ command: String) async throws -> Shell {
        let v2 = hasShellV2
        return Shell(stream: try await open((v2 ? "shell,v2,raw:" : "shell:") + command), v2: v2)
    }

    /** Installs an APK (as `adb install -r`), streamed to `cmd package install`. Throws with the TV's reason. */
    func install(_ apk: URL) async throws {
        let data = try Data(contentsOf: apk)
        let s = try await open("exec:cmd package install -r -S \(data.count)")
        try await s.write(data)
        let answer = String(decoding: await s.readAll(), as: UTF8.self).trimmed
        if !answer.contains("Success") { throw TvError.other(answer.isEmpty ? "The TV didn't say it installed it." : answer) }
    }

    func close() {
        socket.close()
        reader?.cancel()
        let all: [Stream] = lock.withLock {
            let s = Array(streams.values)
            streams = [:]
            return s
        }
        for s in all { s.didClose() }
    }
}

/**
 * ADB's public key format (android_pubkey_encode): the modulus size in words, n0inv (−1/n mod 2³²), the modulus and
 * R² mod n (R = 2²⁰⁴⁸) as little-endian words, and the exponent; base64.
 */
enum AdbKey {
    static func encode(pkcs1: Data) throws -> String {
        guard let numbers = Identity.rsaNumbers(pkcs1: pkcs1) else { throw TvError.other("ADB: bad public key") }
        let words = 64
        var n = [UInt32](repeating: 0, count: words)     // little-endian words
        let m = [UInt8](numbers.modulus)
        guard m.count <= words * 4 else { throw TvError.other("ADB: the key isn't 2048 bits") }
        for (i, byte) in m.reversed().enumerated() { n[i / 4] |= UInt32(byte) << (8 * UInt32(i % 4)) }
        // n0inv: Newton's iteration for the inverse of n[0] mod 2³², negated.
        var x: UInt32 = n[0]
        for _ in 0..<5 { x = x &* (2 &- n[0] &* x) }
        let n0inv = 0 &- x
        // R² mod n, by doubling 1 four thousand and ninety-six times, mod n each time.
        var r = [UInt32](repeating: 0, count: words + 1)
        r[0] = 1
        let nn = n + [0]
        for _ in 0..<(words * 32 * 2) {
            var carry: UInt32 = 0
            for i in 0..<r.count {
                let v = r[i]
                r[i] = (v << 1) | carry
                carry = v >> 31
            }
            if !less(r, nn) { subtract(&r, nn) }
        }
        var out = Data()
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put(UInt32(words))
        put(n0inv)
        for w in n { put(w) }
        for w in r.prefix(words) { put(w) }
        let e = [UInt8](numbers.exponent).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        put(e)
        return out.base64EncodedString()
    }

    private static func less(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }

    private static func subtract(_ a: inout [UInt32], _ b: [UInt32]) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            a[i] = UInt32(truncatingIfNeeded: d)
            borrow = (d >> 63) & 1
        }
    }
}
