import Foundation

// Protocol constants shared with the Java core; see PROTOCOL.md.
enum Wire {
    static let version: UInt8 = 1
    static let roleMac: UInt8 = 1
    static let rolePhone: UInt8 = 2
    static let macPort: UInt16 = 47830
    static let phonePort: UInt16 = 47831
    static let serviceType = "_cunhapfs._tcp"
    static let maxData = 1 << 20
    static let maxPlain = maxData + 64
    static let tagSize = 16
    static let blockSize = 8 << 20
    static let connections = 4
    static let segmentHeader = 16
    static let socketBuffer: Int32 = 4 << 20
    static let handshakeTimeout: TimeInterval = 10
    static let ioTimeout: TimeInterval = 30
}

enum MessageType: UInt8 {
    case info = 0x01
    case offer = 0x02
    case offerMore = 0x03
    case join = 0x04
    case data = 0x05
    case finish = 0x06
    case cancel = 0x07
    case accept = 0x10
    case reject = 0x11
    case done = 0x12
}

struct TransferError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AuthError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    init(_ type: MessageType) { bytes.append(type.rawValue) }

    var count: Int { bytes.count }

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
    mutating func raw(_ data: some Sequence<UInt8>) { bytes.append(contentsOf: data) }

    mutating func string(_ value: String) throws {
        let utf8 = Array(value.utf8)
        guard utf8.count <= 0xFFFF else { throw TransferError("texto longo demais") }
        u16(UInt16(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    mutating func setU32(_ value: UInt32, at offset: Int) {
        withUnsafeBytes(of: value.bigEndian) { raw in
            for i in 0..<4 { bytes[offset + i] = raw[i] }
        }
    }

    static func stringSize(_ value: String) -> Int { 2 + value.utf8.count }
}

struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 { UInt16(try uint(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try uint(4)) }
    mutating func u64() throws -> UInt64 { try uint(8) }

    mutating func raw(_ count: Int) throws -> [UInt8] {
        try need(count)
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func string() throws -> String {
        let count = Int(try u16())
        return String(decoding: try raw(count), as: UTF8.self)
    }

    private mutating func uint(_ size: Int) throws -> UInt64 {
        try need(size)
        var value: UInt64 = 0
        for i in 0..<size { value = value << 8 | UInt64(bytes[offset + i]) }
        offset += size
        return value
    }

    private func need(_ count: Int) throws {
        guard count <= remaining else { throw TransferError("mensagem truncada") }
    }
}

// Big-endian access to raw frame buffers on the hot path.
extension UnsafeMutableRawPointer {
    func storeBE(_ value: UInt32, at offset: Int) { storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt32.self) }
    func storeBE(_ value: UInt64, at offset: Int) { storeBytes(of: value.bigEndian, toByteOffset: offset, as: UInt64.self) }
}

extension UnsafeRawPointer {
    func loadBE32(at offset: Int) -> UInt32 { UInt32(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    func loadBE64(at offset: Int) -> UInt64 { UInt64(bigEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}
