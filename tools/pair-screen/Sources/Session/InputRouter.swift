import AppKit
import Carbon.HIToolbox

// Turns Mac input into scrcpy control messages for the current session.
@MainActor
final class InputRouter {
    var session: MirrorSession?
    var pasteboard: NSPasteboard = .general
    private var pressedKeys: [UInt16: UInt32] = [:]

    private static let specialKeys: [Int: UInt32] = [
        kVK_Return: AndroidKeycode.enter,
        kVK_ANSI_KeypadEnter: AndroidKeycode.enter,
        kVK_Delete: AndroidKeycode.del,
        kVK_ForwardDelete: AndroidKeycode.forwardDel,
        kVK_Tab: AndroidKeycode.tab,
        kVK_Escape: AndroidKeycode.back,
        kVK_LeftArrow: AndroidKeycode.dpadLeft,
        kVK_RightArrow: AndroidKeycode.dpadRight,
        kVK_UpArrow: AndroidKeycode.dpadUp,
        kVK_DownArrow: AndroidKeycode.dpadDown,
        kVK_Home: AndroidKeycode.moveHome,
        kVK_End: AndroidKeycode.moveEnd,
        kVK_PageUp: AndroidKeycode.pageUp,
        kVK_PageDown: AndroidKeycode.pageDown,
    ]

    nonisolated private static let composableMarks: Set<UInt32> = [0x300, 0x301, 0x302, 0x303, 0x308]

    // normalized: 0...1 from the top-left corner of the video.
    func touch(_ action: MotionAction, at normalized: CGPoint) {
        guard let position = position(normalized) else { return }
        let down = action != .up
        send(.injectTouch(
            action: action, pointerID: PointerID.mouse, position: position, pressure: down ? 1 : 0,
            actionButton: action == .move ? 0 : MotionButton.primary, buttons: down ? MotionButton.primary : 0
        ))
    }

    func scroll(at normalized: CGPoint, horizontal: Float, vertical: Float) {
        guard let position = position(normalized), horizontal != 0 || vertical != 0 else { return }
        send(.injectScroll(position: position, hscroll: max(-16, min(16, horizontal)), vscroll: max(-16, min(16, vertical)), buttons: 0))
    }

    func back(_ action: KeyAction) { send(.backOrScreenOn(action: action)) }
    func key(_ keycode: UInt32, _ action: KeyAction, repeatCount: UInt32 = 0, meta: UInt32 = 0) {
        send(.injectKeycode(action: action, keycode: keycode, repeatCount: repeatCount, metaState: meta))
    }

    func press(_ keycode: UInt32, meta: UInt32 = 0) {
        key(keycode, .down, meta: meta)
        key(keycode, .up, meta: meta)
    }

    func pressBack() {
        back(.down)
        back(.up)
    }

    // Special keys map to Android keycodes; returns false for keys that should go through text input.
    func keyDown(_ event: NSEvent) -> Bool {
        guard let keycode = Self.specialKeys[Int(event.keyCode)] else { return false }
        pressedKeys[event.keyCode] = keycode
        key(keycode, .down, repeatCount: event.isARepeat ? 1 : 0, meta: Self.meta(event.modifierFlags))
        return true
    }

    func keyUp(_ event: NSEvent) {
        guard let keycode = pressedKeys.removeValue(forKey: event.keyCode) else { return }
        key(keycode, .up, meta: Self.meta(event.modifierFlags))
    }

    // ⌘V pastes the Mac clipboard; any other ⌘+letter becomes Ctrl+letter on the phone (⌘C copies, ⌘A selects all).
    func commandKey(_ event: NSEvent) -> Bool {
        guard let character = event.charactersIgnoringModifiers?.lowercased().unicodeScalars.first,
              ("a"..."z").contains(character) else { return false }
        if character == "v" {
            pasteFromMac()
        } else {
            press(AndroidKeycode.letterA + (character.value - 0x61), meta: AndroidMeta.ctrlOn | AndroidMeta.ctrlLeftOn)
        }
        return true
    }

    func pasteFromMac() {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        send(.setClipboard(sequence: 0, text: text, paste: true))
    }

    // INJECT_TEXT covers ASCII and accented vowels; other characters (ç, emoji) go through the phone clipboard.
    func insertText(_ text: String) {
        var run = ""
        var runInjectable = true
        func flush() {
            guard !run.isEmpty else { return }
            if runInjectable {
                for chunk in Self.chunks(run, maxBytes: ControlMessage.injectTextMaxLength) { send(.injectText(chunk)) }
            } else {
                send(.setClipboard(sequence: 0, text: run, paste: true))
            }
            run = ""
        }
        for character in text {
            let injectable = Self.isInjectable(character)
            if injectable != runInjectable { flush() }
            runInjectable = injectable
            run.append(character)
        }
        flush()
    }

    private func send(_ message: ControlMessage) { session?.send(message) }

    private func position(_ normalized: CGPoint) -> DevicePosition? {
        guard let size = session?.videoSize, size.width > 0, size.height > 0 else { return nil }
        let x = Int32(max(0, min(CGFloat(size.width) - 1, (normalized.x * CGFloat(size.width)).rounded(.down))))
        let y = Int32(max(0, min(CGFloat(size.height) - 1, (normalized.y * CGFloat(size.height)).rounded(.down))))
        return DevicePosition(x: x, y: y, width: size.width, height: size.height)
    }

    nonisolated static func meta(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var meta: UInt32 = 0
        if flags.contains(.shift) { meta |= AndroidMeta.shiftOn | AndroidMeta.shiftLeftOn }
        if flags.contains(.option) { meta |= AndroidMeta.altOn | AndroidMeta.altLeftOn }
        if flags.contains(.control) { meta |= AndroidMeta.ctrlOn | AndroidMeta.ctrlLeftOn }
        return meta
    }

    nonisolated static func isInjectable(_ character: Character) -> Bool {
        let scalars = String(character).decomposedStringWithCanonicalMapping.unicodeScalars.map(\.value)
        guard let base = scalars.first, (0x20...0x7E).contains(base) else { return false }
        return scalars.dropFirst().allSatisfy { composableMarks.contains($0) }
    }

    nonisolated static func chunks(_ text: String, maxBytes: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if current.utf8.count + String(character).utf8.count > maxBytes {
                result.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
