import AppKit
import Foundation

enum SelfTest {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest-control") {
            exit(ProtocolSelfTest.run() ? 0 : 1)
        }
        if arguments.contains("--selftest-pipeline") {
            MainActor.assumeIsolated { PipelineSelfTest.run(arguments: arguments) }
            return true
        }
        return false
    }

    static func log(_ message: String) {
        FileHandle.standardOutput.write(Data("[pair-screen] \(message)\n".utf8))
    }

    static func value(_ flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
}

// Expected bytes copied from app/tests/test_control_msg_serialize.c and test_device_msg_deserialize.c of scrcpy 4.1.
enum ProtocolSelfTest {
    private static var failures = 0

    static func run() -> Bool {
        failures = 0
        controlMessages()
        deviceMessages()
        helpers()
        SelfTest.log(failures == 0 ? "protocolo: todos os casos passaram" : "protocolo: \(failures) falha(s)")
        return failures == 0
    }

    private static func check(_ name: String, _ message: ControlMessage, _ expected: [UInt8]) {
        let bytes = message.serialized()
        if bytes == expected {
            SelfTest.log("ok   \(name) (\(bytes.count) bytes)")
        } else {
            failures += 1
            SelfTest.log("FALHA \(name): esperado \(hex(expected)) obtido \(hex(bytes))")
        }
    }

    private static func expect(_ name: String, _ condition: Bool) {
        if condition { SelfTest.log("ok   \(name)") } else {
            failures += 1
            SelfTest.log("FALHA \(name)")
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.prefix(48).map { String(format: "%02x", $0) }.joined(separator: " ") + (bytes.count > 48 ? " …(\(bytes.count))" : "")
    }

    private static func controlMessages() {
        check("inject_keycode", .injectKeycode(action: .up, keycode: AndroidKeycode.enter, repeatCount: 5, metaState: AndroidMeta.shiftOn | AndroidMeta.shiftLeftOn),
              [0x00, 0x01, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x41])
        check("inject_text", .injectText("hello, world!"), [0x01, 0x00, 0x00, 0x00, 0x0d] + Array("hello, world!".utf8))
        let longText = String(repeating: "a", count: ControlMessage.injectTextMaxLength)
        check("inject_text_long", .injectText(longText), [0x01, 0x00, 0x00, 0x01, 0x2c] + Array(longText.utf8))
        check("inject_text_truncated", .injectText(longText + "b"), [0x01, 0x00, 0x00, 0x01, 0x2c] + Array(longText.utf8))
        check("inject_touch_event", .injectTouch(
            action: .down, pointerID: 0x1234_5678_8765_4321, position: DevicePosition(x: 100, y: 200, width: 1080, height: 1920),
            pressure: 1, actionButton: MotionButton.primary, buttons: MotionButton.primary
        ), [
            0x02, 0x00,
            0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21,
            0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0xc8,
            0x04, 0x38, 0x07, 0x80,
            0xff, 0xff,
            0x00, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x01,
        ])
        check("inject_scroll_event", .injectScroll(position: DevicePosition(x: 260, y: 1026, width: 1080, height: 1920), hscroll: 16, vscroll: -16, buttons: 1), [
            0x03,
            0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x04, 0x02,
            0x04, 0x38, 0x07, 0x80,
            0x7F, 0xFF,
            0x80, 0x00,
            0x00, 0x00, 0x00, 0x01,
        ])
        check("back_or_screen_on", .backOrScreenOn(action: .up), [0x04, 0x01])
        check("set_clipboard", .setClipboard(sequence: 0x0102_0304_0506_0708, text: "hello, world!", paste: true),
              [0x09, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01, 0x00, 0x00, 0x00, 0x0d] + Array("hello, world!".utf8))
        let max = ControlMessage.clipboardTextMaxLength
        let clipboardText = String(repeating: "a", count: max)
        let header: [UInt8] = [0x09, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x01,
                               UInt8(max >> 24), UInt8((max >> 16) & 0xff), UInt8((max >> 8) & 0xff), UInt8(max & 0xff)]
        let long = ControlMessage.setClipboard(sequence: 0x0102_0304_0506_0708, text: clipboardText, paste: true).serialized()
        expect("set_clipboard_long (\(long.count) bytes)", long.count == ControlMessage.maxSize && Array(long.prefix(14)) == header && long.dropFirst(14).allSatisfy { $0 == 0x61 })
        check("set_display_power", .setDisplayPower(on: true), [0x0a, 0x01])
        check("rotate_device", .rotateDevice, [0x0b])
        check("reset_video", .resetVideo, [0x11])
    }

    private static func deviceMessages() {
        let clipboard: [UInt8] = [0x00, 0x00, 0x00, 0x00, 0x03, 0x41, 0x42, 0x43]
        expect("device clipboard", DeviceMessage.parse(clipboard[...]) == .message(.clipboard("ABC"), consumed: 8))

        let textMax = DeviceMessage.maxSize - 5
        var big: [UInt8] = [0x00, UInt8(textMax >> 24), UInt8((textMax >> 16) & 0xff), UInt8((textMax >> 8) & 0xff), UInt8(textMax & 0xff)]
        big += [UInt8](repeating: 0x61, count: textMax)
        if case let .message(.clipboard(text), consumed) = DeviceMessage.parse(big[...]) {
            expect("device clipboard_big", consumed == DeviceMessage.maxSize && text.utf8.count == textMax && text.first == "a")
        } else {
            expect("device clipboard_big", false)
        }

        let ack: [UInt8] = [0x01, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        expect("device ack_clipboard", DeviceMessage.parse(ack[...]) == .message(.ackClipboard(sequence: 0x0102_0304_0506_0708), consumed: 9))

        let uhid: [UInt8] = [0x02, 0, 42, 0, 5, 0x01, 0x02, 0x03, 0x04, 0x05]
        expect("device uhid_output", DeviceMessage.parse(uhid[...]) == .message(.uhidOutput(id: 42, data: [1, 2, 3, 4, 5]), consumed: 10))

        expect("device incomplete", DeviceMessage.parse(clipboard.dropLast()) == .incomplete)
        expect("device two messages", DeviceMessage.parse((clipboard + ack).dropFirst(8)) == .message(.ackClipboard(sequence: 0x0102_0304_0506_0708), consumed: 9))
    }

    private static func helpers() {
        let stream: [UInt8] = [0, 0, 0, 1, 0x40, 0x01, 0xAA, 0, 0, 1, 0x42, 0x01, 0xBB, 0x00, 0, 0, 0, 1, 0x26, 0x01, 0xCC]
        let units = stream.withUnsafeBufferPointer { AnnexB.nalUnits(in: $0) }
        expect("annexb nal units", units == [4..<7, 10..<13, 18..<21])
        expect("hevc nal types", units.map { VideoCodec.h265.nalType(stream[$0.lowerBound]) } == [32, 33, 19])
        expect("texto injetável", InputRouter.isInjectable("a") && InputRouter.isInjectable("é") && InputRouter.isInjectable("ã") && !InputRouter.isInjectable("ç") && !InputRouter.isInjectable("😀"))
        expect("utf8 truncation", ByteWriter.utf8TruncationIndex(Array("aé".utf8), maxLength: 2) == 1)
    }
}
