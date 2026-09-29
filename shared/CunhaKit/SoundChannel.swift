import Foundation

// Sound Manager state as the suite shows it: output device, audible apps and the menu bar icon.
public struct SoundState: Codable, Equatable, Sendable {
    public struct Output: Codable, Equatable, Sendable {
        public var name: String
        public var volume: Double
        public var muted: Bool
        public var isSoftware: Bool

        public init(name: String, volume: Double, muted: Bool, isSoftware: Bool) {
            self.name = name
            self.volume = volume
            self.muted = muted
            self.isSoftware = isSoftware
        }
    }

    public struct App: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var bundleID: String?
        public var pid: Int32
        public var volume: Double
        public var effectiveVolume: Double
        public var muted: Bool

        public init(id: String, name: String, bundleID: String?, pid: Int32, volume: Double, effectiveVolume: Double, muted: Bool) {
            self.id = id
            self.name = name
            self.bundleID = bundleID
            self.pid = pid
            self.volume = volume
            self.effectiveVolume = effectiveVolume
            self.muted = muted
        }
    }

    public var output: Output?
    public var apps: [App]
    public var showsMenuBarIcon: Bool

    public init(output: Output?, apps: [App], showsMenuBarIcon: Bool) {
        self.output = output
        self.apps = apps
        self.showsMenuBarIcon = showsMenuBarIcon
    }

    // The main volume caps every app.
    public var ceiling: Double { output?.volume ?? 1 }
}

public enum SoundAction: Codable, Equatable, Sendable {
    case requestState
    case setMasterVolume(Double)
    case toggleMasterMute
    case setAppVolume(id: String, volume: Double)
    case toggleAppMute(id: String)
    case setMenuBarIcon(visible: Bool)
}

// Suite ↔ Sound Manager over distributed notifications; the payload is a JSON string, since userInfo takes only property-list types.
public enum SoundChannel {
    public static let bundleID = "com.marcelocunha.soundmanager"
    public static let stateName = Notification.Name("com.marcelocunha.soundmanager.state")
    public static let actionName = Notification.Name("com.marcelocunha.soundmanager.action")
    public static let payloadKey = "json"

    public static func publish(_ state: SoundState) { post(state, name: stateName) }

    public static func send(_ action: SoundAction) { post(action, name: actionName) }

    @MainActor
    public static func observeStates(_ handler: @escaping @MainActor (SoundState) -> Void) -> NSObjectProtocol {
        observe(stateName, handler)
    }

    @MainActor
    public static func observeActions(_ handler: @escaping @MainActor (SoundAction) -> Void) -> NSObjectProtocol {
        observe(actionName, handler)
    }

    public static func stopObserving(_ observer: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(observer)
    }

    // deliverImmediately: both apps are usually inactive, and an inactive app holds back distributed notifications.
    private static func post(_ message: some Encodable, name: Notification.Name) {
        guard let data = try? JSONEncoder().encode(message), let json = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: [payloadKey: json], deliverImmediately: true)
    }

    @MainActor
    private static func observe<Message: Decodable & Sendable>(_ name: Notification.Name, _ handler: @escaping @MainActor (Message) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { notification in
            guard let json = notification.userInfo?[payloadKey] as? String,
                  let message = try? JSONDecoder().decode(Message.self, from: Data(json.utf8)) else { return }
            MainActor.assumeIsolated { handler(message) }
        }
    }
}
