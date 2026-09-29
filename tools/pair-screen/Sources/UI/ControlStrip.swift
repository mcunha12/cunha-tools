import AppKit

enum StripAction {
    case back, home, recents, toggleScreen, rotate, close
}

// Top strip of the overlay: drags the window and shows the phone controls while the mouse is over the overlay.
final class ControlStrip: NSView {
    static let height: CGFloat = 28

    var onAction: ((StripAction) -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var screenButton: NSButton?

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.alphaValue = 0
        let items: [(StripAction, String, String)] = [
            (.back, "chevron.backward", "Voltar"),
            (.home, "circle", "Início"),
            (.recents, "square.on.square", "Recentes"),
            (.toggleScreen, "iphone.gen3", "Desligar a tela do celular"),
            (.rotate, "rotate.right", "Girar"),
            (.close, "xmark", "Fechar"),
        ]
        for (action, symbol, help) in items {
            let button = makeButton(symbol: symbol, help: help, action: action)
            if action == .toggleScreen { screenButton = button }
            if action == .toggleScreen || action == .close { buttons.addView(button, in: .trailing) } else { buttons.addView(button, in: .leading) }
        }
        addSubview(buttons)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    var title: String {
        get { titleLabel.stringValue }
        set { titleLabel.stringValue = newValue }
    }

    func setScreenOn(_ on: Bool) {
        screenButton?.image = NSImage(systemSymbolName: on ? "iphone.gen3" : "iphone.gen3.slash", accessibilityDescription: nil)
        screenButton?.toolTip = on ? "Desligar a tela do celular" : "Ligar a tela do celular"
    }

    func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        guard animated else {
            buttons.alphaValue = visible ? 1 : 0
            titleLabel.alphaValue = visible ? 0 : 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            buttons.animator().alphaValue = visible ? 1 : 0
            titleLabel.animator().alphaValue = visible ? 0 : 1
        }
    }

    override func layout() {
        super.layout()
        buttons.frame = bounds.insetBy(dx: 8, dy: 2)
        titleLabel.frame = NSRect(x: 12, y: (bounds.height - 16) / 2, width: bounds.width - 24, height: 16)
    }

    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func makeButton(symbol: String, help: String, action: StripAction) -> NSButton {
        let button = StripButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: nil, action: nil)
        button.stripAction = action
        button.target = self
        button.action = #selector(buttonPressed(_:))
        button.isBordered = false
        button.contentTintColor = .white
        button.toolTip = help
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    @objc private func buttonPressed(_ sender: StripButton) {
        if let action = sender.stripAction { onAction?(action) }
    }
}

private final class StripButton: NSButton {
    var stripAction: StripAction?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
