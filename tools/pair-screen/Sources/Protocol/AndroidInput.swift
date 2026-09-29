// Android constants used by the scrcpy control protocol (values from android/input.h and android/keycodes.h).
enum KeyAction: UInt8 {
    case down = 0
    case up = 1
}

enum MotionAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
}

enum MotionButton {
    static let primary: UInt32 = 1 << 0
}

enum PointerID {
    static let mouse = UInt64.max
}

enum AndroidKeycode {
    static let home: UInt32 = 3
    static let back: UInt32 = 4
    static let dpadUp: UInt32 = 19
    static let dpadDown: UInt32 = 20
    static let dpadLeft: UInt32 = 21
    static let dpadRight: UInt32 = 22
    static let letterA: UInt32 = 29
    static let tab: UInt32 = 61
    static let enter: UInt32 = 66
    static let del: UInt32 = 67
    static let pageUp: UInt32 = 92
    static let pageDown: UInt32 = 93
    static let forwardDel: UInt32 = 112
    static let moveHome: UInt32 = 122
    static let moveEnd: UInt32 = 123
    static let appSwitch: UInt32 = 187
}

enum AndroidMeta {
    static let shiftOn: UInt32 = 0x01
    static let altOn: UInt32 = 0x02
    static let altLeftOn: UInt32 = 0x10
    static let shiftLeftOn: UInt32 = 0x40
    static let ctrlOn: UInt32 = 0x1000
    static let ctrlLeftOn: UInt32 = 0x2000
}

struct DevicePosition: Equatable {
    var x: Int32
    var y: Int32
    var width: UInt16
    var height: UInt16
}
