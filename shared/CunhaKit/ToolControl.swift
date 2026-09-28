import AppKit
import Foundation

public enum ToolCommand: String, Sendable {
    case launchAtLoginOn
    case launchAtLoginOff
    case openSetup
    case quit
}

// Suite → tool commands over distributed notifications; launch arguments cover a tool that is not running.
public enum ToolControl {
    public static let notificationName = Notification.Name("com.marcelocunha.cunhatools.command")
    public static let launchArgument = "--cunha-command"

    private static var observer: NSObjectProtocol?

    @MainActor
    public static func listen(_ handler: @escaping @MainActor (ToolCommand) -> Void) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: launchArgument), arguments.count > index + 1,
           let command = ToolCommand(rawValue: arguments[index + 1]) {
            DispatchQueue.main.async { handler(command) }
        }
        guard observer == nil, let bundleID = Bundle.main.bundleIdentifier else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: notificationName, object: bundleID, queue: .main) { notification in
            guard let raw = notification.userInfo?["command"] as? String, let command = ToolCommand(rawValue: raw) else { return }
            MainActor.assumeIsolated { handler(command) }
        }
    }

    // Default handling for the commands every tool supports; tools pass their own openSetup action.
    @MainActor
    public static func listen(launchAtLogin: LaunchAtLogin, openSetup: @escaping @MainActor () -> Void) {
        listen { command in
            switch command {
            case .launchAtLoginOn: launchAtLogin.setEnabled(true)
            case .launchAtLoginOff: launchAtLogin.setEnabled(false)
            case .openSetup: openSetup()
            case .quit: NSApp.terminate(nil)
            }
        }
        launchAtLogin.refresh()
    }

    public static func send(_ command: ToolCommand, to bundleID: String) {
        DistributedNotificationCenter.default().postNotificationName(
            notificationName, object: bundleID, userInfo: ["command": command.rawValue], deliverImmediately: true
        )
    }
}

// Each tool writes its state to status/<bundle id>.json; the suite reads it.
public struct ToolStatus: Codable, Equatable, Sendable {
    public var launchAtLogin: Bool
    public var needsApproval: Bool
    public var setupComplete: Bool?
    public var detail: String?
    public var updatedAt: Date

    public static func url(for bundleID: String) -> URL {
        SuitePaths.status.appendingPathComponent("\(bundleID).json")
    }

    public static func read(bundleID: String) -> ToolStatus? {
        guard let data = try? Data(contentsOf: url(for: bundleID)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ToolStatus.self, from: data)
    }

    public static func publish(launchAtLogin: Bool? = nil, needsApproval: Bool? = nil, setupComplete: Bool? = nil, detail: String? = nil) {
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != SuitePaths.suiteBundleID else { return }
        var status = read(bundleID: bundleID) ?? ToolStatus(launchAtLogin: false, needsApproval: false, updatedAt: Date())
        if let launchAtLogin { status.launchAtLogin = launchAtLogin }
        if let needsApproval { status.needsApproval = needsApproval }
        if let setupComplete { status.setupComplete = setupComplete }
        if let detail { status.detail = detail }
        status.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status) else { return }
        try? data.write(to: url(for: bundleID), options: .atomic)
    }
}
