import AppKit

// Green waveform on a tinted rounded square; not a template, so the menu bar keeps the color.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            NSColor.systemGreen.withAlphaComponent(0.18).setFill()
            tile.fill()
            NSColor.systemGreen.withAlphaComponent(0.4).setStroke()
            tile.lineWidth = 1
            tile.stroke()
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold).applying(.init(paletteColors: [.systemGreen]))
            guard let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return true }
            let size = symbol.size
            symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Sound Manager"
        return image
    }()
}
