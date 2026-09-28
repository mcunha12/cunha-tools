import Foundation

// --selftest-ceiling: rules of the main volume as the ceiling of each app, no hardware involved.
enum CeilingSelfTest {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest-ceiling") { exit(MainActor.assumeIsolated { run() }) }
        if arguments.contains("--selftest-master") { exit(MainActor.assumeIsolated { MasterSelfTest.run() }) }
        return false
    }

    private static let curve: (Double) -> Double? = { -60 + 60 * $0 }
    private static let noCurve: (Double) -> Double? = { _ in nil }
    private static let software = MasterLevel(volume: 0.4, hasHardwareVolume: false, hasHardwareMute: false)

    @MainActor
    private static func run() -> Int32 {
        var checks = SelfTestChecks(name: "selftest-ceiling")
        effectiveAndDrag(&checks)
        hardwareGain(&checks)
        softwareGain(&checks)
        model(&checks)
        return checks.finish()
    }

    private static func amplitude(_ scalar: Double) -> Double {
        pow(10, curve(scalar)! / 20)
    }

    private static func gain(_ volume: Double, muted: Bool = false, _ master: MasterLevel, curve: (Double) -> Double? = curve) -> Double {
        Double(VolumeCeiling.gain(app: VolumeSetting(volume: volume, muted: muted), master: master, decibels: curve))
    }

    private static func effectiveAndDrag(_ checks: inout SelfTestChecks) {
        checks.close(VolumeCeiling.effectiveVolume(0.8, ceiling: 0.5), 0.5, "2: app 80%, geral 50% → efetivo 50%")
        checks.close(VolumeCeiling.effectiveVolume(0.3, ceiling: 0.5), 0.3, "2: app 30%, geral 50% → efetivo 30%")
        checks.close(VolumeCeiling.storedVolume(dragged: 0.9, ceiling: 0.5), 0.5, "3: arraste a 90% com teto 50% → salvo 50%")
        checks.close(VolumeCeiling.storedVolume(dragged: 0.3, ceiling: 0.5), 0.3, "3: arraste a 30% com teto 50% → salvo 30%")
        checks.close(VolumeCeiling.storedVolume(dragged: -0.2, ceiling: 0.5), 0, "3: arraste abaixo de 0 → salvo 0%")
    }

    private static func hardwareGain(_ checks: inout SelfTestChecks) {
        let master = MasterLevel(volume: 0.6)
        checks.close(gain(0.3, MasterLevel(volume: 1)), amplitude(0.3) / amplitude(1), "6: app 30%, geral 100% → ganho pela curva do dispositivo")
        checks.close(amplitude(0.6) * gain(0.3, master), amplitude(0.3), "6: app 30% com geral 60% soa igual ao dispositivo em 30%")
        checks.close(gain(0.3, master, curve: noCurve), 0.5, "6: sem conversão para dB → razão linear 30/60")
        checks.close(gain(0.6, master), 1, "6: app igual ao geral → ganho 1, sem tap", tolerance: 0)
        checks.close(gain(0.9, master), 1, "6: app acima do geral → ganho 1, sem tap", tolerance: 0)
        checks.close(gain(0.5, MasterLevel(volume: 0)), 1, "6: geral em 0 → ganho 1, o hardware silencia", tolerance: 0)
        checks.close(gain(0.9, MasterLevel(volume: 0.5, muted: true)), 1, "6: geral mudo → ganho 1, o hardware silencia", tolerance: 0)
        checks.close(gain(0.3, MasterLevel(volume: 0.6, muted: true)), gain(0.3, master), "6: geral mudo mantém o ganho que o app já tinha")
        checks.close(gain(0.3, muted: true, master), 0, "6: app mudo → ganho 0", tolerance: 0)
        checks.close(gain(0, master), 0, "6: app em 0% → ganho 0", tolerance: 0)
        checks.close(gain(0.9, MasterLevel(volume: 0.5, muted: true, hasHardwareMute: false)), 0, "6: dispositivo sem mudo de hardware, geral mudo → ganho 0", tolerance: 0)
    }

    private static func softwareGain(_ checks: inout SelfTestChecks) {
        checks.close(gain(1, software), 0.4, "7: software, app 100%, geral 40% → ganho 0,4")
        checks.close(gain(0.2, software), 0.2, "7: software, app 20%, geral 40% → ganho 0,2")
        checks.close(gain(1, software, curve: { _ in 0 }), 0.4, "7: software ignora a curva do dispositivo")
        checks.close(gain(1, MasterLevel(volume: 1, hasHardwareVolume: false, hasHardwareMute: false)), 1, "7: software, geral 100% → ganho 1, sem tap", tolerance: 0)
        checks.close(gain(1, MasterLevel(volume: 0, hasHardwareVolume: false, hasHardwareMute: false)), 0, "7: software, geral 0% → ganho 0", tolerance: 0)
        checks.close(gain(1, MasterLevel(volume: 0.4, muted: true, hasHardwareVolume: false, hasHardwareMute: false)), 0, "7: software, geral mudo → ganho 0", tolerance: 0)
    }

    @MainActor
    private static func model(_ checks: inout SelfTestChecks) {
        let suite = "com.marcelocunha.soundmanager.ceiling-test"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let app = AppItem(id: "test.app", name: "Teste", bundleID: "test.app", pids: [], audioProcessIDs: [], isPlaying: true)
        let master = MasterVolume(preview: .init(uid: "hardware", name: "Teste", level: MasterLevel()), defaults: defaults)
        let model = AppModel(defaults: defaults, master: master, scan: { [app] })

        model.setVolume(0.8, for: app)
        master.setVolume(0.4)
        checks.close(model.setting(for: app).volume, 0.8, "5: geral baixa a 40% → o app mantém 80% salvo")
        checks.close(model.effectiveVolume(for: app), 0.4, "5: geral em 40% → app limitado a 40%")
        master.setVolume(0.9)
        checks.close(model.effectiveVolume(for: app), 0.8, "5: geral sobe a 90% → app volta a 80%")

        master.setVolume(0.5)
        model.setVolume(0.95, for: app)
        checks.close(model.setting(for: app).volume, 0.5, "3: arraste a 95% com teto 50% → salvo 50%")
        checks.close(master.level.volume, 0.5, "3: arraste acima do teto não eleva o geral")
        model.setVolume(0.2, for: app)
        checks.close(master.level.volume, 0.5, "4: baixar o app não altera o geral")
        model.toggleMute(for: app)
        checks.expect(!master.level.muted, "4: mudo do app não altera o mudo do geral")
        model.toggleMute(for: app)
        checks.close(Double(model.gain(for: app)), 0.4, "6: sem curva, app 20% com geral 50% → ganho 0,4")

        let softwareLevel = MasterLevel(hasHardwareVolume: false, hasHardwareMute: false)
        let first = MasterVolume(preview: .init(uid: "device-a", name: "A", level: softwareLevel), defaults: defaults)
        let second = MasterVolume(preview: .init(uid: "device-b", name: "B", level: softwareLevel), defaults: defaults)
        first.setVolume(0.4)
        second.setVolume(0.7)
        second.toggleMute()
        let reloaded = MasterVolume(preview: .init(uid: "device-c", name: "C", level: softwareLevel), defaults: defaults)
        checks.close(reloaded.savedSoftwareLevel(uid: "device-a").volume, 0.4, "7: geral por software salvo por UID (A = 40%)")
        checks.close(reloaded.savedSoftwareLevel(uid: "device-b").volume, 0.7, "7: geral por software salvo por UID (B = 70%)")
        checks.expect(reloaded.savedSoftwareLevel(uid: "device-b").muted, "7: mudo por software salvo por UID")
        checks.close(reloaded.savedSoftwareLevel(uid: "hardware").volume, 1, "7: dispositivo com volume de hardware não grava geral por software")

        let other = AppItem(id: "test.other", name: "Outro", bundleID: "test.other", pids: [], audioProcessIDs: [], isPlaying: true)
        let softwareModel = AppModel(defaults: defaults, master: first, scan: { [other] })
        checks.close(Double(softwareModel.gain(for: other)), 0.4, "7: software, app sem ajuste com geral 40% → ganho 0,4")
    }
}

struct SelfTestChecks {
    let name: String
    private var passed = 0
    private var failed = 0

    init(name: String) {
        self.name = name
    }

    mutating func expect(_ condition: Bool, _ label: String) {
        print("\(condition ? "ok   " : "FALHA") \(label)")
        if condition { passed += 1 } else { failed += 1 }
    }

    mutating func close(_ actual: Double, _ expected: Double, _ label: String, tolerance: Double = 1e-6) {
        expect(abs(actual - expected) <= tolerance, "\(label) [obtido \(String(format: "%.6f", actual)), esperado \(String(format: "%.6f", expected))]")
    }

    func finish() -> Int32 {
        print("\(name): \(passed) ok, \(failed) falha(s)")
        return failed == 0 ? 0 : 1
    }
}
