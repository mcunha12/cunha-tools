import AppKit
import CunhaKit
import SwiftUI

enum DebugRender {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-ui"), arguments.count > index + 1 else { return false }
        let output = URL(fileURLWithPath: arguments[index + 1])
        let expanded = arguments.firstIndex(of: "--expand").flatMap { arguments.count > $0 + 1 ? Set([arguments[$0 + 1]]) : nil } ?? []
        let delay = arguments.firstIndex(of: "--wait").flatMap { arguments.count > $0 + 1 ? Double(arguments[$0 + 1]) : nil } ?? 2

        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        MainActor.assumeIsolated {
            let model = arguments.contains("--demo") ? demoModel(software: arguments.contains("--software")) : AppModel()
            let bridge = BrowserBridge()
            bridge.start()
            let root = MenuContentView(initiallyExpanded: expanded)
                .environmentObject(model)
                .environmentObject(model.master)
                .environmentObject(bridge)
                .environmentObject(LaunchAtLogin())
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 1) {
                guard arguments.contains("--send-test-commands"), let session = bridge.sessions.values.first, let tab = session.tabs.first else { return }
                bridge.setVolume(0.25, tab: tab, session: session.id)
                bridge.setMuted(true, tab: tab, session: session.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                snapshot(hosting, window: window, to: output)
                UserDefaults().removePersistentDomain(forName: demoSuite)
                exit(0)
            }
        }
        application.run()
        return true
    }

    private static let demoSuite = "com.marcelocunha.soundmanager.render-demo"

    // --demo: three running apps as if playing, main volume at 60% and saved volumes 90%, 35% and 100%.
    @MainActor
    private static func demoModel(software: Bool) -> AppModel {
        UserDefaults().removePersistentDomain(forName: demoSuite)
        let defaults = UserDefaults(suiteName: demoSuite)!
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }.prefix(3)
        let apps = running.map { app in
            AppItem(id: app.bundleIdentifier ?? "pid-\(app.processIdentifier)", name: app.localizedName ?? "App", bundleID: app.bundleIdentifier, pids: [app.processIdentifier], audioProcessIDs: [], isPlaying: true)
        }
        let level = MasterLevel(hasHardwareVolume: !software, hasHardwareMute: !software)
        let name = OutputDeviceControls.defaultDevice()?.name ?? "Saída de áudio"
        let master = MasterVolume(preview: .init(uid: "demo", name: name, level: level), defaults: defaults)
        var saved = VolumeSettingsStore(defaults: defaults, key: VolumeSettingsStore.appsKey)
        for (app, volume) in zip(apps, [0.9, 0.35, 1]) { saved[app.id] = VolumeSetting(volume: volume) }
        master.setVolume(0.6)
        return AppModel(defaults: defaults, master: master, scan: { apps })
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
