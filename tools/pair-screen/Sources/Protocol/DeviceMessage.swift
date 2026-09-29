// Device → client messages, parsed like app/src/device_msg.c of scrcpy 4.1.
enum DeviceMessage: Equatable {
    static let maxSize = 1 << 18

    case clipboard(String)
    case ackClipboard(sequence: UInt64)
    case uhidOutput(id: UInt16, data: [UInt8])

    enum ParseResult: Equatable {
        case message(DeviceMessage, consumed: Int)
        case incomplete
        case invalid
    }

    static func parse(_ buffer: ArraySlice<UInt8>) -> ParseResult {
        guard let type = buffer.first else { return .incomplete }
        let base = buffer.startIndex
        let available = buffer.count
        switch type {
        case 0:
            guard available >= 5 else { return .incomplete }
            let length = Int(readU32(buffer, at: base + 1))
            guard length <= available - 5 else { return .incomplete }
            let text = String(decoding: buffer[(base + 5)..<(base + 5 + length)], as: UTF8.self)
            return .message(.clipboard(text), consumed: 5 + length)
        case 1:
            guard available >= 9 else { return .incomplete }
            let sequence = UInt64(readU32(buffer, at: base + 1)) << 32 | UInt64(readU32(buffer, at: base + 5))
            return .message(.ackClipboard(sequence: sequence), consumed: 9)
        case 2:
            guard available >= 5 else { return .incomplete }
            let id = UInt16(buffer[base + 1]) << 8 | UInt16(buffer[base + 2])
            let size = Int(buffer[base + 3]) << 8 | Int(buffer[base + 4])
            guard size <= available - 5 else { return .incomplete }
            return .message(.uhidOutput(id: id, data: Array(buffer[(base + 5)..<(base + 5 + size)])), consumed: 5 + size)
        default:
            return .invalid
        }
    }

    private static func readU32(_ buffer: ArraySlice<UInt8>, at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(buffer[index + $1]) }
    }
}
