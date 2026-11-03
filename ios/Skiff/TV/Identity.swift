import Foundation
import Security

/**
 * This phone's keys, made once and kept in the Keychain (never leaving the phone):
 *  - the remote protocol's client certificate: RSA 2048, self-signed ("CN=Skiff"), as a TLS identity;
 *  - the ADB key: RSA 2048, its public half sent to the TV the first time ("Allow USB debugging?").
 */
enum Identity {
    private static let atvTag = "dev.skiff.atv-client"
    private static let atvLabel = "Skiff remote"
    private static let adbTag = "dev.skiff.adbkey"

    enum KeyError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
    }

    // MARK: Keys

    /** The private key tagged `tag`, made (RSA 2048, in the Keychain) when there's none. */
    static func rsaKey(tag: String) throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item {
            return (item as! SecKey)
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Data(tag.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as [String: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw KeyError.failed("Couldn't make a key: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return key
    }

    /** A public key's PKCS#1 form (RSAPublicKey: modulus, exponent). */
    static func publicKeyData(_ key: SecKey) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(key) else { throw KeyError.failed("No public key") }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw KeyError.failed("Couldn't read the public key")
        }
        return data
    }

    /** An RSA public key's modulus and exponent (from its PKCS#1 form). */
    static func rsaNumbers(pkcs1 data: Data) -> Messages.RsaKey? {
        guard let seq = Der.read(data), seq.tag == 0x30, let items = Der.children(seq.content), items.count >= 2 else { return nil }
        return Messages.RsaKey(modulus: Messages.unsigned(items[0].content), exponent: Messages.unsigned(items[1].content))
    }

    /** A certificate's RSA public key numbers (the TV's, for the pairing secret). */
    static func rsaNumbers(certificate: SecCertificate) -> Messages.RsaKey? {
        guard let key = SecCertificateCopyKey(certificate), let data = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return rsaNumbers(pkcs1: data)
    }

    // MARK: The remote protocol's client certificate

    /** The TLS identity for the TV: our certificate and its key, made once. */
    static func atvIdentity() throws -> (identity: SecIdentity, certificate: SecCertificate) {
        let key = try rsaKey(tag: atvTag)
        if let found = findIdentity(for: key) { return found }
        let der = try selfSignedCertificate(key: key)
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else { throw KeyError.failed("Couldn't make the certificate") }
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: atvLabel,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw KeyError.failed("Couldn't keep the certificate (\(status))") }
        guard let found = findIdentity(for: key) else { throw KeyError.failed("Couldn't find the identity") }
        return found
    }

    /** The Keychain's identity (certificate + private key) whose certificate holds `key`'s public half. */
    private static func findIdentity(for key: SecKey) -> (identity: SecIdentity, certificate: SecCertificate)? {
        guard let want = try? publicKeyData(key) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let array = result as? [AnyObject] else { return nil }
        for obj in array {
            let identity = obj as! SecIdentity
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
                  let pub = SecCertificateCopyKey(cert), let data = SecKeyCopyExternalRepresentation(pub, nil) as Data?,
                  data == want else { continue }
            return (identity, cert)
        }
        return nil
    }

    /** "CN=Skiff, O=Skiff", self-signed with SHA-256, valid for 30 years. */
    static func selfSignedCertificate(key: SecKey) throws -> Data {
        let pkcs1 = try publicKeyData(key)
        let rsaAlgorithm = Der.sequence([Der.oid([1, 2, 840, 113549, 1, 1, 1]), Der.null])
        let spki = Der.sequence([rsaAlgorithm, Der.bitString(pkcs1)])
        let signatureAlgorithm = Der.sequence([Der.oid([1, 2, 840, 113549, 1, 1, 11]), Der.null])    // sha256WithRSAEncryption
        let name = Der.sequence([
            Der.set([Der.sequence([Der.oid([2, 5, 4, 3]), Der.utf8("Skiff")])]),     // CN
            Der.set([Der.sequence([Der.oid([2, 5, 4, 10]), Der.utf8("Skiff")])]),    // O
        ])
        let now = Date()
        let end = Calendar(identifier: .gregorian).date(byAdding: .year, value: 30, to: now) ?? now
        var serial = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F    // positive
        serial[0] |= 0x01    // and no leading zero
        let tbs = Der.sequence([
            Der.tagged(0xA0, Der.integer(Data([2]))),    // version 3
            Der.integer(Data(serial)),
            signatureAlgorithm,
            name,
            Der.sequence([Der.time(now), Der.time(end)]),
            name,
            spki,
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            throw KeyError.failed("Couldn't sign the certificate: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        }
        return Der.sequence([tbs, signatureAlgorithm, Der.bitString(signature)])
    }

    // MARK: ADB

    /** The ADB private key, made once. */
    static func adbKey() throws -> SecKey { try rsaKey(tag: adbTag) }
}

/** Just enough DER to write a certificate and read an RSA public key. */
enum Der {
    static func encode(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var len = [UInt8]()
            var v = n
            while v > 0 { len.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(len.count))
            out.append(contentsOf: len)
        }
        out.append(content)
        return out
    }

    static func sequence(_ items: [Data]) -> Data { encode(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { encode(0x31, items.reduce(Data(), +)) }
    static func tagged(_ tag: UInt8, _ inner: Data) -> Data { encode(tag, inner) }
    static let null = Data([0x05, 0x00])
    static func utf8(_ s: String) -> Data { encode(0x0C, Data(s.utf8)) }
    static func bitString(_ d: Data) -> Data { encode(0x03, Data([0]) + d) }

    /** A non-negative integer from big-endian bytes (a 0 in front when the top bit is set). */
    static func integer(_ d: Data) -> Data {
        var b = [UInt8](d)
        while b.count > 1 && b[0] == 0 && b[1] & 0x80 == 0 { b.removeFirst() }
        if let f = b.first, f & 0x80 != 0 { b.insert(0, at: 0) }
        return encode(0x02, Data(b))
    }

    static func oid(_ parts: [UInt]) -> Data {
        var out = Data([UInt8(parts[0] * 40 + parts[1])])
        for p in parts.dropFirst(2) {
            var stack = [UInt8(p & 0x7F)]
            var v = p >> 7
            while v > 0 { stack.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            out.append(contentsOf: stack)
        }
        return encode(0x06, out)
    }

    /** UTCTime until 2049, GeneralizedTime from 2050 (as X.509 says). */
    static func time(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date).year ?? 2000
        if year < 2050 {
            f.dateFormat = "yyMMddHHmmss'Z'"
            return encode(0x17, Data(f.string(from: date).utf8))
        }
        f.dateFormat = "yyyyMMddHHmmss'Z'"
        return encode(0x18, Data(f.string(from: date).utf8))
    }

    struct Element {
        let tag: UInt8
        let content: Data
        let length: Int    // the whole element, header included
    }

    /** The element at the start of `data`. */
    static func read(_ data: Data) -> Element? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        var i = 1
        var len = Int(b[i])
        i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n <= 4, b.count >= i + n else { return nil }
            len = 0
            for _ in 0..<n { len = (len << 8) | Int(b[i]); i += 1 }
        }
        guard b.count >= i + len else { return nil }
        return Element(tag: b[0], content: Data(b[i..<(i + len)]), length: i + len)
    }

    /** The elements inside a constructed element's content. */
    static func children(_ content: Data) -> [Element]? {
        var out: [Element] = []
        var rest = content
        while !rest.isEmpty {
            guard let e = read(rest) else { return nil }
            out.append(e)
            rest = Data(rest.dropFirst(e.length))
        }
        return out
    }
}
