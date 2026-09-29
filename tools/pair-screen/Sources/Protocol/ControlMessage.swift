import Foundation

// Client → device messages, serialized exactly like app/src/control_msg.c of scrcpy 4.1.
enum ControlMessage {
    static let maxSize = 1 << 18
    static let injectTextMaxLength = 300
    static let clipboardTextMaxLength = maxSize - 14

    case injectKeycode(action: KeyAction, keycode: UInt32, repeatCount: UInt32, metaState: UInt32)
    case injectText(String)
    case injectTouch(action: MotionAction, pointerID: UInt64, position: DevicePosition, pressure: Float, actionButton: UInt32, buttons: UInt32)
    case injectScroll(position: DevicePosition, hscroll: Float, vscroll: Float, buttons: UInt32)
    case backOrScreenOn(action: KeyAction)
    case setClipboard(sequence: UInt64, text: String, paste: Bool)
    case setDisplayPower(on: Bool)
    case rotateDevice
    case resetVideo

    private var typeCode: UInt8 {
        switch self {
        case .injectKeycode: 0
        case .injectText: 1
        case .injectTouch: 2
        case .injectScroll: 3
        case .backOrScreenOn: 4
        case .setClipboard: 9
        case .setDisplayPower: 10
        case .rotateDevice: 11
        case .resetVideo: 17
        }
    }

    func serialized() -> [UInt8] {
        var out = ByteWriter()
        out.u8(typeCode)
        switch self {
        case let .injectKeycode(action, keycode, repeatCount, metaState):
            out.u8(action.rawValue)
            out.u32(keycode)
            out.u32(repeatCount)
            out.u32(metaState)
        case let .injectText(text):
            out.string(text, maxLength: Self.injectTextMaxLength)
        case let .injectTouch(action, pointerID, position, pressure, actionButton, buttons):
            out.u8(action.rawValue)
            out.u64(pointerID)
            out.position(position)
            out.u16(Self.unsignedFixedPoint(pressure))
            out.u32(actionButton)
            out.u32(buttons)
        case let .injectScroll(position, hscroll, vscroll, buttons):
            out.position(position)
            out.u16(UInt16(bitPattern: Self.signedFixedPoint(hscroll / 16)))
            out.u16(UInt16(bitPattern: Self.signedFixedPoint(vscroll / 16)))
            out.u32(buttons)
        case let .backOrScreenOn(action):
            out.u8(action.rawValue)
        case let .setClipboard(sequence, text, paste):
            out.u64(sequence)
            out.u8(paste ? 1 : 0)
            out.string(text, maxLength: Self.clipboardTextMaxLength)
        case let .setDisplayPower(on):
            out.u8(on ? 1 : 0)
        case .rotateDevice, .resetVideo:
            break
        }
        return out.bytes
    }

    // Same rounding as sc_float_to_u16fp: [0, 1] → [0, 0xffff].
    static func unsignedFixedPoint(_ value: Float) -> UInt16 {
        let clamped = min(max(value, 0), 1)
        return UInt16(min(UInt32(clamped * 65536), 0xffff))
    }

    // Same rounding as sc_float_to_i16fp: [-1, 1] → [-0x8000, 0x7fff].
    static func signedFixedPoint(_ value: Float) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return Int16(min(Int32(clamped * 32768), 0x7fff))
    }
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func u8(_ value: UInt8) { bytes.append(value) }
    mutating func u16(_ value: UInt16) { bytes += [UInt8(value >> 8), UInt8(value & 0xff)] }
    mutating func u32(_ value: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8((value >> UInt32(shift)) & 0xff)) } }
    mutating func u64(_ value: UInt64) { u32(UInt32(value >> 32)); u32(UInt32(value & 0xffff_ffff)) }

    mutating func position(_ position: DevicePosition) {
        u32(UInt32(bitPattern: position.x))
        u32(UInt32(bitPattern: position.y))
        u16(position.width)
        u16(position.height)
    }

    // Length (u32) + UTF-8 bytes, truncated without splitting a character.
    mutating func string(_ text: String, maxLength: Int) {
        let utf8 = Array(text.utf8)
        let length = Self.utf8TruncationIndex(utf8, maxLength: maxLength)
        u32(UInt32(length))
        bytes += utf8[0..<length]
    }

    static func utf8TruncationIndex(_ utf8: [UInt8], maxLength: Int) -> Int {
        guard utf8.count > maxLength else { return utf8.count }
        var index = maxLength
        while index > 0, utf8[index] & 0xC0 == 0x80 { index -= 1 }
        return index
    }
}
