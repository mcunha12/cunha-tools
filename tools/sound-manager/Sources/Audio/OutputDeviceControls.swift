import AudioToolbox
import CoreAudio

// Volume and mute of one output device, read and written on the device itself.
struct OutputDeviceControls {
    static let volumeSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    static let muteSelector = kAudioDevicePropertyMute
    private static let scope = kAudioDevicePropertyScopeOutput

    let id: AudioObjectID

    static func defaultDevice() -> OutputDeviceControls? {
        let device: AudioObjectID = AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: .unknown)
        return device == .unknown ? nil : OutputDeviceControls(id: device)
    }

    var uid: String? { id.readString(kAudioDevicePropertyDeviceUID) }
    var name: String { id.readString(kAudioObjectPropertyName) ?? "Saída de áudio" }

    var hasVolume: Bool { id.has(Self.volumeSelector, scope: Self.scope) && id.isSettable(Self.volumeSelector, scope: Self.scope) }
    var hasMute: Bool { id.has(Self.muteSelector, scope: Self.scope) && id.isSettable(Self.muteSelector, scope: Self.scope) }

    var volume: Double? {
        let value: Float32 = id.read(Self.volumeSelector, scope: Self.scope, default: -1)
        return value >= 0 ? Double(min(value, 1)) : nil
    }

    var muted: Bool? {
        guard id.has(Self.muteSelector, scope: Self.scope) else { return nil }
        let value: UInt32 = id.read(Self.muteSelector, scope: Self.scope, default: 0)
        return value != 0
    }

    @discardableResult
    func setVolume(_ volume: Double) -> Bool {
        id.write(Self.volumeSelector, scope: Self.scope, Float32(min(max(volume, 0), 1)))
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        id.write(Self.muteSelector, scope: Self.scope, UInt32(muted ? 1 : 0))
    }

    // The device's own scalar → dB curve; the main element first, then channel 1.
    func decibels(forScalar scalar: Double) -> Double? {
        for element in [kAudioObjectPropertyElementMain, 1] where id.has(kAudioDevicePropertyVolumeScalarToDecibels, scope: Self.scope, element: element) {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalarToDecibels, mScope: Self.scope, mElement: element)
            var value = Float32(scalar)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, value.isFinite { return Double(value) }
        }
        return nil
    }
}
