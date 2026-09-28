import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLogin: ObservableObject {
    private static let defaultAppliedKey = "launchAtLoginDefaultApplied"

    @Published public private(set) var status = SMAppService.mainApp.status

    public init() {}

    public var isEnabled: Bool { status == .enabled }
    public var needsApproval: Bool { status == .requiresApproval }

    public var isInstalled: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }

    public func applyDefault() {
        guard isInstalled, !UserDefaults.standard.bool(forKey: Self.defaultAppliedKey) else { return }
        setEnabled(true)
        if isEnabled || needsApproval { UserDefaults.standard.set(true, forKey: Self.defaultAppliedKey) }
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("\(ProcessInfo.processInfo.processName): item de início não atualizado: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(true, forKey: Self.defaultAppliedKey)
        refresh()
    }

    public func refresh() {
        let current = SMAppService.mainApp.status
        if current != status { status = current }
        ToolStatus.publish(launchAtLogin: isEnabled, needsApproval: needsApproval)
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
