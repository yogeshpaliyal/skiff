import CryptoKit
import Foundation

/**
 * The messages of the Android TV Remote protocol (v2), with their field numbers from github.com/tronikos/androidtvremote2
 * (polo.proto: pairing on port 6467; remotemessage.proto: the remote on 6466). (atv/Messages.kt)
 */
enum Messages {
    // MARK: Pairing (polo.proto: OuterMessage)

    private static let statusOk = 200
    static let encodingHexadecimal = 3
    static let roleInput = 1

    private static func outer(_ body: (inout ProtoWriter) -> Void) -> Data {
        ProtoWriter.build { w in
            w.varint(1, 2)            // protocol_version
            w.varint(2, statusOk)     // status
            body(&w)
        }
    }

    /** PairingRequest(service_name, client_name): the TV then shows the code. */
    static func pairingRequest(_ clientName: String) -> Data {
        outer { $0.message(10) { $0.string(1, "atvremote"); $0.string(2, clientName) } }
    }

    /** Options: we type a 6-character hexadecimal code. */
    static func options() -> Data {
        outer { w in
            w.message(20) { o in
                o.message(1) { $0.varint(1, encodingHexadecimal); $0.varint(2, 6) }   // input_encodings
                o.varint(3, roleInput)                                                 // preferred_role
            }
        }
    }

    /** Configuration: the same encoding, we're the input. */
    static func configuration() -> Data {
        outer { w in
            w.message(30) { c in
                c.message(1) { $0.varint(1, encodingHexadecimal); $0.varint(2, 6) }   // encoding
                c.varint(2, roleInput)                                                 // client_role
            }
        }
    }

    static func secret(_ secret: Data) -> Data { outer { $0.message(40) { $0.bytes(1, secret) } } }

    /** An OuterMessage from the TV: its status, and which step it answers. */
    struct Outer {
        let status: Int
        let isPairingRequestAck: Bool
        let isOptions: Bool
        let isConfigurationAck: Bool
        let isSecretAck: Bool

        init(_ bytes: Data) throws {
            let r = try ProtoReader(bytes)
            status = r.int(2)
            isPairingRequestAck = r.has(11)
            isOptions = r.has(20)
            isConfigurationAck = r.has(31)
            isSecretAck = r.has(41)
        }
    }

    /** An RSA public key's numbers, big-endian, without a sign byte. */
    struct RsaKey: Equatable {
        var modulus: Data
        var exponent: Data
    }

    /**
     * The secret for a code shown on the TV ("A1B2C3"): SHA-256 over the client's RSA modulus and exponent, the TV's,
     * and the code's last 4 hex digits (2 bytes). The code's first byte is the hash's first byte: a typo check. Nil
     * when the code doesn't match these certificates (mistyped).
     */
    static func pairingSecret(client: RsaKey, server: RsaKey, code: String) -> Data? {
        let c = code.trimmed.uppercased()
        guard Re("[0-9A-F]{6}").matches(c) else { return nil }
        var sha = SHA256()
        sha.update(data: unsigned(client.modulus))
        sha.update(data: unsigned(client.exponent))
        sha.update(data: unsigned(server.modulus))
        sha.update(data: unsigned(server.exponent))
        sha.update(data: hex(String(c.dropFirst(2))))
        let hash = Data(sha.finalize())
        return Int(hash[hash.startIndex]) == Int(c.prefix(2), radix: 16) ? hash : nil
    }

    /** A positive number's big-endian bytes without leading zero bytes (Python's bytes.fromhex(f"{n:X}")). */
    static func unsigned(_ n: Data) -> Data {
        var b = [UInt8](n)
        while b.count > 1 && b[0] == 0 { b.removeFirst() }
        return Data(b)
    }

    static func hex(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex, let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex) {
            out.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    // MARK: Remote (remotemessage.proto: RemoteMessage)

    static let featurePing = 1
    static let featureKey = 2
    static let featureIme = 4
    static let featurePower = 32
    static let featureVolume = 64
    static let featureAppLink = 512
    static let features = featurePing | featureKey | featureIme | featurePower | featureVolume | featureAppLink

    // Key directions: a press, or held down (a modifier: Shift) and let go.
    static let directionDown = 1
    static let directionUp = 2
    static let directionShort = 3

    /** Our RemoteConfigure: the features we use (those the TV supports), and who we are. */
    static func remoteConfigure(_ features: Int) -> Data {
        ProtoWriter.build { w in
            w.message(1) { c in
                c.varint(1, features)
                c.message(2) { d in
                    d.varint(3, 1)                // unknown1
                    d.string(4, "1")              // unknown2
                    d.string(5, "dev.skiff")      // package_name
                    d.string(6, "1.0.0")          // app_version
                }
            }
        }
    }

    static func remoteSetActive(_ features: Int) -> Data { ProtoWriter.build { $0.message(2) { $0.varint(1, features) } } }

    static func pingResponse(_ val1: Int) -> Data { ProtoWriter.build { $0.message(9) { $0.varint(1, val1) } } }

    /** A key press: the key codes are Android's own (KeyEvent.KEYCODE_*). */
    static func keyInject(_ keyCode: Int, direction: Int = directionShort) -> Data {
        ProtoWriter.build { $0.message(10) { $0.varint(1, keyCode); $0.varint(2, direction) } }
    }

    /** Opens a link on the TV, in the app that opens it. */
    static func appLink(_ link: String) -> Data { ProtoWriter.build { $0.message(90) { $0.string(1, link) } } }

    /** Text into the TV's focused field, by its input method (it sent its counters when the field got focus). */
    static func imeText(ime: Int, field: Int, text: String, insert: Int = 1) -> Data {
        // The cursor as androidtvremote2 puts it: on the last character (on none for an empty field). In UTF-16 units,
        // as Android counts them.
        let cursor = max(text.utf16.count - 1, 0)
        return ProtoWriter.build { w in
            w.message(21) { e in
                e.varint(1, ime)
                e.varint(2, field)
                e.message(3) { o in
                    o.varint(1, insert)
                    o.message(2) { $0.varint(1, cursor); $0.varint(2, cursor); $0.string(3, text) }
                }
            }
        }
    }

    /** A RemoteMessage from the TV. */
    struct Remote {
        let configure: ProtoReader?
        let setActive: Bool
        let error: Bool
        let pingVal1: Int?
        let imeBatchEdit: ProtoReader?
        /** The focused text field's counter, as the TV announces it (key inject 20, show request 22). */
        let imeFieldCounter: Int?
        /** The focused field's text. */
        let imeFieldText: String?
        /** The input method's counter for the focused field: app_info.counter of the TV's key inject (20). */
        let imeAppCounter: Int?
        let start: ProtoReader?
        let fields: Set<Int>

        init(_ bytes: Data) throws {
            let r = try ProtoReader(bytes)
            configure = r.message(1)
            setActive = r.has(2)
            error = r.has(3)
            pingVal1 = r.message(8)?.int(1)
            imeBatchEdit = r.message(21)
            let focus = r.message(20) ?? r.message(22)
            let status = focus?.message(2)
            imeFieldCounter = (status?.has(1) ?? false) ? status?.int(1) : nil
            if let status, status.has(2) {
                imeFieldText = status.string(2)
            } else if let v = r.message(21)?.message(3)?.message(2), v.has(3) {
                imeFieldText = v.string(3)
            } else {
                imeFieldText = nil
            }
            let app = r.message(20)?.message(1)
            imeAppCounter = (app?.has(1) ?? false) ? app?.int(1) : nil
            start = r.message(40)
            fields = r.fields
        }
    }
}
