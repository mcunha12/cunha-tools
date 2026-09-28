import AppKit
import SwiftUI

// --render-ui <png> [--light|--dark] [--wait s]: draws the main window offscreen, without a scroll view.
enum DebugRender {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-ui"), arguments.count > index + 1 else { return false }
        let output = URL(fileURLWithPath: arguments[index + 1])
        let delay = arguments.firstIndex(of: "--wait").flatMap { arguments.count > $0 + 1 ? Double(arguments[$0 + 1]) : nil } ?? 2.5

        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated {
            let tools = ToolsModel()
            let root = MainView(scrolls: false)
                .environmentObject(tools)
                .frame(width: 600)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            if arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
            if arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
            window.contentView = hosting
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                snapshot(hosting, window: window, to: output)
                exit(0)
            }
        }
        application.run()
        return true
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
