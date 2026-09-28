import CoreAudio
import Foundation

// --selftest-router: tap lifetime on a real audio process, with gains close to 1 so nothing is audible.
enum RouterSelfTest {
    @MainActor
    static func run() -> Int32 {
        var checks = SelfTestChecks(name: "selftest-router")
        guard let target = targetProcesses() else {
            checks.expect(false, "processo de áudio para o teste")
            return checks.finish()
        }
        let router = AudioRouter()
        let custom = { (gain: Float) in RouteRequest(key: "custom", processObjectIDs: target, gain: gain, keepsTap: true) }
        router.apply([custom(1)])
        checks.expect(router.activeKeys.contains("custom"), "app com volume próprio no teto já tem tap")
        wait(2.5)
        router.apply([custom(1)])
        checks.expect(router.activeKeys.contains("custom"), "app com volume próprio mantém o tap após 2,5 s no teto")
        let start = DispatchTime.now().uptimeNanoseconds
        router.apply([custom(0.999)])
        let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        checks.expect(milliseconds < 5, String(format: "subir o geral só troca o ganho do tap (%.2f ms)", milliseconds))
        router.stopAll()

        let plain = { (gain: Float) in RouteRequest(key: "plain", processObjectIDs: target, gain: gain, keepsTap: false) }
        router.apply([plain(1)])
        checks.expect(!router.activeKeys.contains("plain"), "app em 100% não ganha tap")
        router.apply([plain(0.999)])
        router.apply([plain(1)])
        checks.expect(router.activeKeys.contains("plain"), "app de volta a 100% mantém o tap por 2 s")
        wait(2.5)
        router.apply([plain(1)])
        checks.expect(!router.activeKeys.contains("plain"), "app de volta a 100% perde o tap após 2 s")
        router.stopAll()
        return checks.finish()
    }

    private static func targetProcesses() -> Set<AudioObjectID>? {
        if let own = AudioProcess.ownObjectID() { return [own] }
        return AudioProcess.all().first.map { [$0.objectID] }
    }

    private static func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
