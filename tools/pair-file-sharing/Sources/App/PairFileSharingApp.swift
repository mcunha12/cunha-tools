import AppKit
import CunhaKit

enum PairFileSharingApp {
    private static var delegate: AppDelegate?

    static func run() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            self.delegate = delegate
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let center = TransferCenter()
    private let launchAtLogin = LaunchAtLogin()
    private let notifier = Notifier()
    private let services = ServicesProvider()
    private var statusItem: StatusItemController?
    private var pendingURLs: [URL] = []
    private lazy var pairingWindow = PairingWindowController(center: center)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifier.setup()
        center.notifier = notifier
        center.openPairing = { [weak self] in self?.openPairing() }
        center.start()
        statusItem = StatusItemController(center: center, launchAtLogin: launchAtLogin, openPairing: { [weak self] in self?.openPairing() })
        services.handler = { [weak self] urls in
            self?.center.send(urls)
            self?.statusItem?.showPopover()
        }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        launchAtLogin.applyDefault()
        ToolControl.listen(launchAtLogin: launchAtLogin, openSetup: { [weak self] in self?.openPairing() })
        if CommandLine.arguments.contains("--pair") { openPairing() }
        if !pendingURLs.isEmpty { application(NSApp, open: pendingURLs) }
        pendingURLs = []
    }

    // `open -a "Pair File Sharing" <files>` sends them to the phone; at launch this arrives before didFinishLaunching.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard statusItem != nil else { return pendingURLs += files }
        center.send(files)
        statusItem?.showPopover()
    }

    func applicationWillTerminate(_ notification: Notification) {
        center.stop()
    }

    private func openPairing() {
        pairingWindow.show()
    }
}
