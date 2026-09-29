import AppKit
import CunhaKit
import SwiftUI

@main
enum Main {
    static func main() {
        if SelfTest.runIfRequested() || CeilingSelfTest.runIfRequested() || DebugRender.runIfRequested() { return }
        SoundManagerApp.main()
    }
}

struct SoundManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var menuBarIcon = MenuBarIconSetting.shared

    var body: some Scene {
        MenuBarExtra(isInserted: $menuBarIcon.isVisible) {
            MenuContentView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.master)
                .environmentObject(delegate.bridge)
                .environmentObject(delegate.launchAtLogin)
        } label: {
            Image(nsImage: MenuBarIcon.image).renderingMode(.original)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let bridge = BrowserBridge()
    let launchAtLogin = LaunchAtLogin()
    private var remote: RemoteControl?

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridge.start()
        ToolStatus.publish(setupComplete: model.permission == .authorized)
        model.requestPermissionIfNeeded()
        launchAtLogin.applyDefault()
        ToolControl.listen(launchAtLogin: launchAtLogin, openSetup: model.requestPermission)
        remote = RemoteControl(delegate: self)
    }

    // Opening the app again while it runs brings back a hidden menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarIconSetting.shared.isVisible = true
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
