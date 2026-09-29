import AVFoundation
import AppKit

// Shows the decoded frames and turns mouse, trackpad and keyboard input into phone input.
final class VideoView: NSView, NSTextInputClient {
    let displayLayer = AVSampleBufferDisplayLayer()
    let router: InputRouter
    var videoSize = CGSize(width: 1080, height: 2340)
    private var touching = false
    private var markedText = ""

    // Android scrolls 64 dp per scroll unit; a phone is about 411 dp across its short side.
    private static let phoneShortSideDp: CGFloat = 411
    private static let dpPerScrollUnit: CGFloat = 64

    init(router: InputRouter) {
        self.router = router
        super.init(frame: .zero)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override func makeBackingLayer() -> CALayer { displayLayer }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func normalized(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) {
            window?.performDrag(with: event)
            return
        }
        touching = true
        router.touch(.down, at: normalized(event))
    }

    override func mouseDragged(with event: NSEvent) {
        if touching { router.touch(.move, at: normalized(event)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard touching else { return }
        touching = false
        router.touch(.up, at: normalized(event))
    }

    override func rightMouseDown(with event: NSEvent) { router.back(.down) }
    override func rightMouseUp(with event: NSEvent) { router.back(.up) }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { router.key(AndroidKeycode.home, .down) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { router.key(AndroidKeycode.home, .up) }
    }

    override func scrollWheel(with event: NSEvent) {
        var horizontal = -event.scrollingDeltaX
        var vertical = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            let shortSide = max(1, min(bounds.width, bounds.height))
            let factor = Self.phoneShortSideDp / shortSide / Self.dpPerScrollUnit
            horizontal *= factor
            vertical *= factor
        }
        router.scroll(at: normalized(event), horizontal: Float(horizontal), vertical: Float(vertical))
    }

    override func keyDown(with event: NSEvent) {
        if router.keyDown(event) { return }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) { router.keyUp(event) }

    // Key equivalents stop here, so ⌘Q or ⌘W from the default menu never fire while the phone has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        _ = router.commandKey(event)
        return true
    }

    override func doCommand(by selector: Selector) {}

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !text.isEmpty { router.insertText(text) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    func unmarkText() { markedText = "" }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count) }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }
}
