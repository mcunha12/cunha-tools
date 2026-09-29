import AppKit
import CunhaKit
import SwiftUI

@main
enum Main {
    static func main() {
        if SelfTest.runIfRequested() { return }
        PairScreenApp.main()
    }
}

struct PairScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(delegate.mirror)
                .environmentObject(delegate.settings)
                .environmentObject(delegate.launchAtLogin)
        } label: {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = MirrorSettings()
    lazy var mirror = MirrorController(settings: settings)
    let launchAtLogin = LaunchAtLogin()

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchAtLogin.applyDefault()
        ToolControl.listen(launchAtLogin: launchAtLogin) { [mirror] in mirror.connect() }
        Task { await mirror.refreshDevice() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mirror.disconnect()
    }
}
