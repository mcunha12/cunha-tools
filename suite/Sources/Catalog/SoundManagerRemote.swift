import AppKit
import CunhaKit

// Suite side of SoundChannel: the last state from Sound Manager and the actions sent to it.
@MainActor
final class SoundManagerRemote: ObservableObject {
    enum Target: Hashable {
        case master
        case app(String)

        func volumeAction(_ volume: Double) -> SoundAction {
            switch self {
            case .master: .setMasterVolume(volume)
            case let .app(id): .setAppVolume(id: id, volume: volume)
            }
        }
    }

    static let sendInterval: TimeInterval = 0.05
    private static let holdDuration: TimeInterval = 0.5
    private static let answerTimeout: TimeInterval = 2

    @Published private(set) var state: SoundState?
    @Published private(set) var isUnresponsive = false
    @Published private var held: [Target: Double] = [:]
    @Published private var heldIcon: Bool?

    private var heldUntil: [Target: Date] = [:]
    private var pending: [Target: Double] = [:]
    private var isThrottling = false
    private var isRunning = RunningTool.isRunning(SoundChannel.bundleID)
    private var stateObserver: NSObjectProtocol?
    private var runningObservation: NSKeyValueObservation?
    private var icons: [String: NSImage] = [:]

    func start() {
        guard stateObserver == nil else { return }
        stateObserver = SoundChannel.observeStates { [weak self] in self?.receive($0) }
        runningObservation = RunningTool.observeRunningApps { [weak self] in self?.runningAppsDidChange() }
        isRunning = RunningTool.isRunning(SoundChannel.bundleID)
        requestState()
    }

    func stop() {
        stateObserver.map(SoundChannel.stopObserving)
        stateObserver = nil
        runningObservation = nil
    }

    func requestState() {
        isUnresponsive = false
        SoundChannel.send(.requestState)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.answerTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state == nil, self.isRunning else { return }
                self.isUnresponsive = true
            }
        }
    }

    // While dragging, the slider shows the local value; late echoes do not pull the knob back.
    var masterVolume: Double { held[.master] ?? state?.output?.volume ?? 0 }

    func volume(of app: SoundState.App) -> Double { held[.app(app.id)] ?? app.effectiveVolume }

    var showsMenuBarIcon: Bool { heldIcon ?? state?.showsMenuBarIcon ?? true }

    // At most one message per control every sendInterval, always ending with the last value.
    func setVolume(_ volume: Double, for target: Target) {
        held[target] = volume
        heldUntil[target] = Date().addingTimeInterval(Self.holdDuration)
        pending[target] = volume
        if !isThrottling { flush() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration) { [weak self] in
            MainActor.assumeIsolated { self?.releaseHold(target) }
        }
    }

    // A volume still waiting in the throttle goes first; sent after the toggle, it would unmute again.
    func toggleMute(for target: Target) {
        if let volume = pending.removeValue(forKey: target) { SoundChannel.send(target.volumeAction(volume)) }
        switch target {
        case .master: SoundChannel.send(.toggleMasterMute)
        case let .app(id): SoundChannel.send(.toggleAppMute(id: id))
        }
    }

    func setMenuBarIcon(visible: Bool) {
        heldIcon = visible
        SoundChannel.send(.setMenuBarIcon(visible: visible))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.heldIcon = nil }
        }
    }

    func icon(for app: SoundState.App) -> NSImage {
        if let icon = icons[app.id] { return icon }
        let bundleURL = app.bundleID.flatMap(NSWorkspace.shared.urlForApplication(withBundleIdentifier:))
        let icon = NSRunningApplication(processIdentifier: app.pid)?.icon
            ?? bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        icons[app.id] = icon
        return icon
    }

    // A state posted while the tool quits can arrive after the running list drops it.
    private func receive(_ new: SoundState) {
        guard isRunning else { return }
        state = new
        isUnresponsive = false
        if heldIcon == new.showsMenuBarIcon { heldIcon = nil }
    }

    private func runningAppsDidChange() {
        let running = RunningTool.isRunning(SoundChannel.bundleID)
        guard running != isRunning else { return }
        isRunning = running
        if running {
            requestState()
        } else {
            state = nil
            held.removeAll()
            pending.removeAll()
        }
    }

    private func flush() {
        guard !pending.isEmpty else {
            isThrottling = false
            return
        }
        for (target, volume) in pending { SoundChannel.send(target.volumeAction(volume)) }
        pending.removeAll()
        isThrottling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sendInterval) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func releaseHold(_ target: Target) {
        guard let until = heldUntil[target], until <= Date() else { return }
        heldUntil[target] = nil
        held[target] = nil
    }
}
