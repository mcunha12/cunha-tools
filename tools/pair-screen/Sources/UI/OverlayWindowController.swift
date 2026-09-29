import AVFoundation
import AppKit

// Owns the floating phone window: size locked to the video aspect, position kept across sessions and launches.
@MainActor
final class OverlayWindowController: NSObject, NSWindowDelegate {
    let panel: OverlayPanel
    let root: OverlayRootView
    private(set) var videoSize = CGSize(width: 1080, height: 2340)
    private let defaults: UserDefaults
    private var anchor = NSPoint.zero
    private var applyingFrame = false
    private static let minVideoWidth: CGFloat = 200

    init(router: InputRouter, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        root = OverlayRootView(router: router)
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 780), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.contentView = root
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        let frame = initialFrame()
        anchor = NSPoint(x: frame.minX, y: frame.maxY)
        panel.setFrame(frame, display: false)
    }

    var renderer: AVSampleBufferVideoRenderer { root.videoView.displayLayer.sampleBufferRenderer }
    var windowNumber: Int { panel.windowNumber }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(root.videoView)
    }

    func hide() { panel.orderOut(nil) }

    func setAlwaysOnTop(_ onTop: Bool) { panel.level = onTop ? .floating : .normal }

    func setStatus(_ text: String?) { root.status = text }

    func setTitle(_ title: String) { root.strip.title = title }

    // New capture session: keep the long side of the video area and the user's top-left corner, then fit the screen.
    func apply(videoSize newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0 else { return }
        let changed = abs(newSize.width / newSize.height - videoSize.width / videoSize.height) > 0.001
        videoSize = newSize
        root.videoView.videoSize = newSize
        guard changed else { return }
        let area = videoArea(of: panel.frame.size)
        let frame = fitted(size: scaled(newSize, longSide: max(area.width, area.height)), topLeft: anchor)
        applyingFrame = true
        panel.setFrame(frame, display: true)
        applyingFrame = false
        panel.invalidateShadow()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let aspect = videoSize.width / videoSize.height
        let current = sender.frame.size
        if abs(frameSize.width - current.width) >= abs(frameSize.height - current.height) {
            let width = max(Self.minVideoWidth, frameSize.width)
            return NSSize(width: width, height: (width / aspect).rounded() + ControlStrip.height)
        }
        let height = max(Self.minVideoWidth, frameSize.height - ControlStrip.height)
        return NSSize(width: max(Self.minVideoWidth, (height * aspect).rounded()), height: height + ControlStrip.height)
    }

    func windowDidResize(_ notification: Notification) {
        panel.invalidateShadow()
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func videoArea(of size: NSSize) -> NSSize {
        NSSize(width: size.width, height: max(1, size.height - ControlStrip.height))
    }

    private func scaled(_ size: CGSize, longSide: CGFloat) -> NSSize {
        let factor = longSide / max(size.width, size.height)
        return NSSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }

    // Shrinks the video area to fit the visible screen and moves the frame back inside it.
    private func fitted(size: NSSize, topLeft: NSPoint) -> NSRect {
        let screen = (NSScreen.screens.first { $0.frame.contains(topLeft) } ?? panel.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var video = size
        let limit = NSSize(width: screen.width * 0.95, height: screen.height * 0.95 - ControlStrip.height)
        let shrink = min(1, limit.width / video.width, limit.height / video.height)
        video = NSSize(width: (video.width * shrink).rounded(), height: (video.height * shrink).rounded())
        var frame = NSRect(x: topLeft.x, y: topLeft.y - video.height - ControlStrip.height, width: video.width, height: video.height + ControlStrip.height)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        return frame
    }

    private func initialFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let saved = defaults.array(forKey: "overlayFrame") as? [Double], saved.count == 3 {
            return fitted(size: scaled(videoSize, longSide: saved[2]), topLeft: NSPoint(x: saved[0], y: saved[1]))
        }
        let size = scaled(videoSize, longSide: min(screen.height * 0.75, 860))
        return fitted(size: size, topLeft: NSPoint(x: screen.maxX - size.width - 40, y: screen.midY + (size.height + ControlStrip.height) / 2))
    }

    private func saveFrame() {
        guard !applyingFrame else { return }
        anchor = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let area = videoArea(of: panel.frame.size)
        defaults.set([panel.frame.minX, panel.frame.maxY, max(area.width, area.height)], forKey: "overlayFrame")
    }
}
