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
                .frame(minWidth: 560, minHeight: 520)
        }
        .defaultSize(width: 600, height: 780)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tools = ToolsModel()

    // The suite is a manager, not a resident app: closing the window quits it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
