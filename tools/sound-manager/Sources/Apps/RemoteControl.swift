import Combine
import CunhaKit
import Foundation

// Sound Manager side of SoundChannel: applies the suite's actions and publishes the state after each change.
@MainActor
final class RemoteControl {
    private static let coalescing: TimeInterval = 0.03

    private unowned let delegate: AppDelegate
    private var observer: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []
    private var lastPublished: SoundState?
    private var isPublishScheduled = false

    private var model: AppModel { delegate.model }

    init(delegate: AppDelegate) {
        self.delegate = delegate
        observer = SoundChannel.observeActions { [weak self] in self?.handle($0) }
        for publisher in [MenuBarIconSetting.shared.objectWillChange, delegate.model.objectWillChange, delegate.model.master.objectWillChange, delegate.bridge.objectWillChange] {
            publisher.sink { [weak self] in
                MainActor.assumeIsolated { self?.schedulePublish() }
            }
            .store(in: &subscriptions)
        }
        publish(force: true)
    }

    private func handle(_ action: SoundAction) {
        switch action {
        case .requestState: publish(force: true)
        case let .setMasterVolume(volume): model.master.setVolume(volume)
        case .toggleMasterMute: model.master.toggleMute()
        case let .setAppVolume(id, volume):
            if let app = app(id) { model.setVolume(volume, for: app) }
        case let .toggleAppMute(id):
            if let app = app(id) { model.toggleMute(for: app) }
        case let .setMenuBarIcon(visible): MenuBarIconSetting.shared.isVisible = visible
        }
    }

    private func app(_ id: String) -> AppItem? {
        model.apps.first { $0.id == id }
    }

    // objectWillChange fires before the new value lands; the short delay also folds a drag's burst into one message.
    private func schedulePublish() {
        guard !isPublishScheduled else { return }
        isPublishScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalescing) { [weak self] in
            MainActor.assumeIsolated {
                self?.isPublishScheduled = false
                self?.publish(force: false)
            }
        }
    }

    private func publish(force: Bool) {
        let state = snapshot()
        guard force || state != lastPublished else { return }
        lastPublished = state
        SoundChannel.publish(state)
    }

    private func snapshot() -> SoundState {
        let output = model.master.device.map {
            SoundState.Output(name: $0.name, volume: $0.level.volume, muted: $0.level.muted, isSoftware: !$0.level.hasHardwareVolume)
        }
        let apps = model.visibleApps(bridge: delegate.bridge).map { app in
            let setting = model.setting(for: app)
            return SoundState.App(
                id: app.id, name: app.name, bundleID: app.bundleID, pid: app.pids.first ?? 0,
                volume: setting.volume, effectiveVolume: model.effectiveVolume(for: app), muted: setting.muted
            )
        }
        return SoundState(output: output, apps: apps, showsMenuBarIcon: MenuBarIconSetting.shared.isVisible)
    }
}
