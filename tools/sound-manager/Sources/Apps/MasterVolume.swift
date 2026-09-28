import Combine
import CoreAudio
import Foundation

// Volume and mute of the default output device; follows the volume keys and device switches.
@MainActor
final class MasterVolume: ObservableObject {
    struct Device: Equatable {
        let uid: String
        let name: String
        var level: MasterLevel
    }

    @Published private(set) var device: Device?
    var onChange: (() -> Void)?

    private var store: VolumeSettingsStore
    private var controls: OutputDeviceControls?
    private var deviceObservations: [PropertyObservation] = []
    private var defaultDeviceObservation: PropertyObservation?

    init(defaults: UserDefaults = .standard) {
        store = VolumeSettingsStore(defaults: defaults, key: VolumeSettingsStore.softwareMasterKey)
        defaultDeviceObservation = PropertyObservation(.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.bindDefaultDevice()
        }
        bindDefaultDevice()
    }

    // Fixed device for the UI render and the self-tests; nothing reaches the hardware.
    init(preview: Device, defaults: UserDefaults) {
        store = VolumeSettingsStore(defaults: defaults, key: VolumeSettingsStore.softwareMasterKey)
        device = preview
    }

    var level: MasterLevel { device?.level ?? MasterLevel() }

    var decibelCurve: (Double) -> Double? {
        let controls = controls
        return { controls?.decibels(forScalar: $0) }
    }

    func savedSoftwareLevel(uid: String) -> VolumeSetting {
        store[uid]
    }

    func setVolume(_ volume: Double) {
        guard var target = device else { return }
        target.level.volume = min(max(volume, 0), 1)
        if target.level.volume > 0 { target.level.muted = false }
        apply(target)
    }

    func toggleMute() {
        guard var target = device else { return }
        target.level.muted.toggle()
        apply(target)
    }

    private func apply(_ target: Device) {
        let level = target.level
        if level.hasHardwareVolume { controls?.setVolume(level.volume) }
        if level.hasHardwareMute, level.muted != device?.level.muted { controls?.setMuted(level.muted) }
        if !level.hasHardwareVolume || !level.hasHardwareMute {
            var saved = store[target.uid]
            if !level.hasHardwareVolume { saved.volume = level.volume }
            if !level.hasHardwareMute { saved.muted = level.muted }
            store[target.uid] = saved
        }
        publish(target)
    }

    private func bindDefaultDevice() {
        deviceObservations.removeAll()
        controls = OutputDeviceControls.defaultDevice()
        if let controls {
            deviceObservations = [OutputDeviceControls.volumeSelector, OutputDeviceControls.muteSelector].map { selector in
                PropertyObservation(controls.id, selector, scope: kAudioDevicePropertyScopeOutput) { [weak self] in self?.reload() }
            }
        }
        reload()
    }

    private func reload() {
        guard let controls, let uid = controls.uid else { return publish(nil) }
        let saved = store[uid]
        let hasVolume = controls.hasVolume
        let hasMute = controls.hasMute
        let level = MasterLevel(
            volume: hasVolume ? controls.volume ?? 1 : saved.volume,
            muted: hasMute ? controls.muted ?? false : saved.muted,
            hasHardwareVolume: hasVolume,
            hasHardwareMute: hasMute
        )
        publish(Device(uid: uid, name: controls.name, level: level))
    }

    private func publish(_ new: Device?) {
        guard new != device else { return }
        device = new
        onChange?()
    }
}
