import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if SelfTest.runIfRequested() || DebugRender.runIfRequested() { return }
        CunhaToolsApp.main()
    }
}

struct CunhaToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Cunha Tools", id: "main") {
            MainView()
                .environmentObject(delegate.tools)
                .environmentObject(delegate.phone)
                .environmentObject(delegate.updater)
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 760)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tools = ToolsModel()
    let phone = PhoneModel()
    let updater = SuiteUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
        if tools.needsPhone { phone.start() }
    }

    // The suite is a manager, not a resident app: closing the window quits it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        phone.stop()
    }
}
