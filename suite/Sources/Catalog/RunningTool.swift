import AppKit
import CunhaKit

@MainActor
enum RunningTool {
    static func instances(of bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    static func isRunning(_ bundleID: String) -> Bool { !instances(of: bundleID).isEmpty }

    // Launch and terminate notifications skip agent apps, and every tool is one; the running list reports them.
    static func observeRunningApps(_ handler: @escaping @MainActor () -> Void) -> NSKeyValueObservation {
        NSWorkspace.shared.observe(\.runningApplications) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated(handler) }
        }
    }

    // Polite quit over ToolControl first, then terminate, then force.
    static func quit(bundleID: String) async {
        guard isRunning(bundleID) else { return }
        ToolControl.send(.quit, to: bundleID)
        if await waitForExit(bundleID, seconds: 3) { return }
        instances(of: bundleID).forEach { $0.terminate() }
        if await waitForExit(bundleID, seconds: 3) { return }
        instances(of: bundleID).forEach { $0.forceTerminate() }
        _ = await waitForExit(bundleID, seconds: 2)
    }

    static func open(_ appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    // A running tool gets the command over ToolControl; a closed one is opened with it as a launch argument.
    static func send(_ command: ToolCommand, bundleID: String, appURL: URL) async throws {
        if isRunning(bundleID) {
            ToolControl.send(command, to: bundleID)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [ToolControl.launchArgument, command.rawValue]
        configuration.activates = command == .openSetup
        try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }

    // Turns the login item off before the bundle goes to the Trash; the tool must run to unregister itself.
    static func prepareRemoval(bundleID: String, appURL: URL, launchAtLogin: Bool) async {
        if isRunning(bundleID) {
            ToolControl.send(.launchAtLoginOff, to: bundleID)
            try? await Task.sleep(for: .milliseconds(600))
        } else if launchAtLogin {
            try? await send(.launchAtLoginOff, bundleID: bundleID, appURL: appURL)
            _ = await waitForLaunch(bundleID, seconds: 5)
            try? await Task.sleep(for: .milliseconds(1500))
        }
        await quit(bundleID: bundleID)
    }

    private static func waitForExit(_ bundleID: String, seconds: Double) async -> Bool {
        await poll(seconds: seconds) { !isRunning(bundleID) }
    }

    private static func waitForLaunch(_ bundleID: String, seconds: Double) async -> Bool {
        await poll(seconds: seconds) { instances(of: bundleID).contains(where: \.isFinishedLaunching) }
    }

    private static func poll(seconds: Double, until condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }
}
