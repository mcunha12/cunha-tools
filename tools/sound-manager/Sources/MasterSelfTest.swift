import CoreAudio
import Foundation

// --selftest-master: writes the default output device, checks the reading and restores the original values.
enum MasterSelfTest {
    private final class Counter {
        var value = 0
    }

    @MainActor
    static func run() -> Int32 {
        var checks = SelfTestChecks(name: "selftest-master")
        guard let controls = OutputDeviceControls.defaultDevice(), let uid = controls.uid else {
            checks.expect(false, "dispositivo de saída padrão encontrado")
            return checks.finish()
        }
        let originalVolume = controls.volume
        let originalMuted = controls.muted
        print("dispositivo: \(controls.name) uid=\(uid) volume de hardware=\(controls.hasVolume) mudo de hardware=\(controls.hasMute)")
        print("original: volume=\(describe(originalVolume)) mudo=\(originalMuted.map(String.init) ?? "-") dB(30%)=\(describe(controls.decibels(forScalar: 0.3))) dB(100%)=\(describe(controls.decibels(forScalar: 1)))")

        listOutputDevices()
        exercise(controls, &checks)

        if let originalVolume, controls.hasVolume { controls.setVolume(originalVolume) }
        if let originalMuted, controls.hasMute { controls.setMuted(originalMuted) }
        spin(0.3)
        if let originalVolume, controls.hasVolume { checks.close(controls.volume ?? -1, originalVolume, "volume original restaurado", tolerance: 0.005) }
        if let originalMuted, controls.hasMute { checks.expect(controls.muted == originalMuted, "mudo original restaurado") }
        print("final: volume=\(describe(controls.volume)) mudo=\(controls.muted.map(String.init) ?? "-")")
        return checks.finish()
    }

    @MainActor
    private static func exercise(_ controls: OutputDeviceControls, _ checks: inout SelfTestChecks) {
        guard controls.hasVolume, let original = controls.volume else {
            print("sem volume de hardware: o geral funciona por software; nada a escrever no dispositivo")
            return
        }
        let suite = "com.marcelocunha.soundmanager.master-test"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let events = Counter()
        let observation = PropertyObservation(controls.id, OutputDeviceControls.volumeSelector, scope: kAudioDevicePropertyScopeOutput) { events.value += 1 }
        defer { observation.cancel() }
        let master = MasterVolume(defaults: UserDefaults(suiteName: suite)!)
        checks.expect(master.device?.level.hasHardwareVolume == true, "MasterVolume detecta volume de hardware")
        checks.close(master.level.volume, original, "MasterVolume lê o volume atual", tolerance: 0.001)

        let external = original > 0.5 ? original - 0.25 : original + 0.25
        checks.expect(controls.setVolume(external), "escrita de volume aceita pelo dispositivo")
        spin(0.5)
        checks.close(controls.volume ?? -1, external, "leitura confere com o valor escrito", tolerance: 0.02)
        checks.expect(events.value > 0, "listener de volume disparou (\(events.value) evento(s))")
        checks.close(master.level.volume, controls.volume ?? -1, "MasterVolume acompanha mudança feita fora do app", tolerance: 0.001)

        let internalTarget = original > 0.5 ? original - 0.1 : original + 0.1
        master.setVolume(internalTarget)
        spin(0.5)
        checks.close(controls.volume ?? -1, internalTarget, "MasterVolume.setVolume escreve no dispositivo", tolerance: 0.02)

        guard controls.hasMute, let muted = controls.muted else { return print("sem mudo de hardware") }
        master.toggleMute()
        spin(0.5)
        checks.expect(controls.muted == !muted, "mudo alternado no dispositivo")
        checks.expect(master.level.muted == !muted, "MasterVolume acompanha o mudo")
    }

    private static func listOutputDevices() {
        for id in AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyDevices) {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { continue }
            let controls = OutputDeviceControls(id: id)
            print("saída disponível: \(controls.name) volume de hardware=\(controls.hasVolume) mudo de hardware=\(controls.hasMute)")
        }
    }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func describe(_ value: Double?) -> String {
        value.map { String(format: "%.4f", $0) } ?? "-"
    }
}
