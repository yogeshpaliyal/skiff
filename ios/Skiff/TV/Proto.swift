import Foundation

/**
 * The little protobuf the Android TV Remote protocol needs (polo.proto and remotemessage.proto in
 * github.com/tronikos/androidtvremote2): varints, strings, bytes and nested messages, framed by a varint length.
 * No library: a handful of messages, each built by hand. (atv/Proto.kt)
 */
struct ProtoWriter {
    private(set) var data = Data()

    @discardableResult
    mutating func varint(_ field: Int, _ value: Int) -> ProtoWriter {
        tag(field, 0)
        ProtoWriter.writeVarint(&data, UInt64(bitPattern: Int64(value)))
        return self
    }

    @discardableResult
    mutating func bool(_ field: Int, _ value: Bool) -> ProtoWriter { varint(field, value ? 1 : 0) }

    @discardableResult
    mutating func bytes(_ field: Int, _ value: Data) -> ProtoWriter {
        tag(field, 2)
        ProtoWriter.writeVarint(&data, UInt64(value.count))
        data.append(value)
        return self
    }

    @discardableResult
    mutating func string(_ field: Int, _ value: String) -> ProtoWriter { bytes(field, Data(value.utf8)) }

    @discardableResult
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) -> ProtoWriter {
        var inner = ProtoWriter()
        build(&inner)
        return bytes(field, inner.data)
    }

    private mutating func tag(_ field: Int, _ wireType: Int) { ProtoWriter.writeVarint(&data, UInt64((field << 3) | wireType)) }

    static func writeVarint(_ out: inout Data, _ value: UInt64) {
        var v = value
        while true {
            if v & ~0x7F == 0 {
                out.append(UInt8(v))
                return
            }
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
    }

    /** One message on the wire: its length as a varint, then its bytes. */
    static func frame(_ message: Data) -> Data {
        var out = Data()
        writeVarint(&out, UInt64(message.count))
        out.append(message)
        return out
    }

    /** Builds one message. */
    static func build(_ body: (inout ProtoWriter) -> Void) -> Data {
        var w = ProtoWriter()
        body(&w)
        return w.data
    }
}

enum ProtoError: Error { case truncated, malformed(String) }

/** The fields of one message: varints and length-delimited values, by field number (the last one wins). */
struct ProtoReader {
    private var varints: [Int: UInt64] = [:]
    private var blobs: [Int: Data] = [:]

    init(_ data: Data) throws {
        let b = [UInt8](data)
        var i = 0
        func readVarint() throws -> UInt64 {
            var shift: UInt64 = 0
            var result: UInt64 = 0
            while true {
                guard i < b.count else { throw ProtoError.truncated }
                let byte = b[i]
                i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { throw ProtoError.malformed("varint too long") }
            }
        }
        while i < b.count {
            let key = try readVarint()
            let field = Int(key >> 3)
            switch key & 7 {
            case 0: varints[field] = try readVarint()
            case 2:
                let len = Int(try readVarint())
                guard len >= 0, i + len <= b.count else { throw ProtoError.truncated }
                blobs[field] = Data(b[i..<(i + len)])
                i += len
            case 1: i += 8
            case 5: i += 4
            default: throw ProtoError.malformed("wire type \(key & 7)")
            }
        }
    }

    func has(_ field: Int) -> Bool { varints[field] != nil || blobs[field] != nil }
    var fields: Set<Int> { Set(varints.keys).union(blobs.keys) }
    func int(_ field: Int) -> Int { Int(truncatingIfNeeded: varints[field] ?? 0) }
    func bool(_ field: Int) -> Bool { (varints[field] ?? 0) != 0 }
    func string(_ field: Int) -> String { blobs[field].map { String(decoding: $0, as: UTF8.self) } ?? "" }
    func message(_ field: Int) -> ProtoReader? { blobs[field].flatMap { try? ProtoReader($0) } }
}
