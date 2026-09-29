import AVFoundation
import AppKit

// Borderless panel that takes keyboard focus without activating the app.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Rounded black container: control strip on top, video below, status text over the video.
final class OverlayRootView: NSView {
    let strip = ControlStrip()
    let videoView: VideoView
    private let statusLabel = NSTextField(labelWithString: "")

    init(router: InputRouter) {
        videoView = VideoView(router: router)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        addSubview(videoView)
        addSubview(strip)
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    var status: String? {
        get { statusLabel.isHidden ? nil : statusLabel.stringValue }
        set {
            statusLabel.stringValue = newValue ?? ""
            statusLabel.isHidden = newValue == nil
        }
    }

    override func layout() {
        super.layout()
        let stripHeight = ControlStrip.height
        strip.frame = NSRect(x: 0, y: bounds.height - stripHeight, width: bounds.width, height: stripHeight)
        videoView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - stripHeight))
        statusLabel.frame = NSRect(x: 8, y: videoView.frame.midY - 10, width: bounds.width - 16, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { strip.setControlsVisible(true) }
    override func mouseExited(with event: NSEvent) { strip.setControlsVisible(false) }
}
