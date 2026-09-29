import AppKit
import SwiftUI

// --render-ui <png> [--page inicio|celular|<tool>] [--guide] [--contribute] [--phone] [--qr] [--light|--dark] [--wait s]: sidebar and page offscreen, without scroll or split view.
enum DebugRender {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-ui"), arguments.count > index + 1 else { return false }
        let output = URL(fileURLWithPath: arguments[index + 1])
        let delay = value(after: "--wait", in: arguments).flatMap(Double.init) ?? 2.5

        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated {
            let tools = ToolsModel()
            let phone = PhoneModel()
            let showsPhone = tools.needsPhone || arguments.contains("--phone")
            if showsPhone { phone.start() }
            if arguments.contains("--qr") { phone.showPairingPreview(.random()) }
            let page = page(named: value(after: "--page", in: arguments), in: tools)
            let layout = HStack(alignment: .top, spacing: 0) {
                Sidebar(page: .constant(page), showsPhone: showsPhone)
                    .frame(width: 250)
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Divider()
                PageContent(page: .constant(page), showsPhone: showsPhone, opensGuide: arguments.contains("--guide"))
                    .frame(width: 830)
                    .background(Palette.canvas)
            }
            let content = arguments.contains("--contribute") ? AnyView(ContributeView().background(Palette.canvas)) : AnyView(layout)
            let root = content
                .tint(Palette.accent)
                .environmentObject(tools)
                .environmentObject(phone)
                .environmentObject(SuiteUpdater())
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1080, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            if arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
            if arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
            window.contentView = hosting
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                snapshot(hosting, window: window, to: output)
                phone.stop()
                exit(0)
            }
        }
        application.run()
        return true
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.count > $0 + 1 ? arguments[$0 + 1] : nil }
    }

    @MainActor
    private static func page(named name: String?, in tools: ToolsModel) -> Page {
        switch name?.lowercased() {
        case nil, "inicio": return .overview
        case "celular": return .phone
        case let name?:
            let match = tools.entries.first { $0.tool.name.lowercased() == name || $0.id == name }
            return match.map { .tool($0.id) } ?? .overview
        }
    }

    @MainActor
    private static func snapshot(_ view: NSView, window: NSWindow, to url: URL) {
        let size = view.fittingSize
        window.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
