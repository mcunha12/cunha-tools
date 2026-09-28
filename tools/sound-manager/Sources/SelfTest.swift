import CoreAudio
import Foundation

enum SelfTest {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        if arguments.contains("--list-audio") {
            listAudio()
            return true
        }
        if let index = arguments.firstIndex(of: "--model-test"), arguments.count > index + 1 {
            MainActor.assumeIsolated { runModelTest(appID: arguments[index + 1]) }
            return true
        }
        guard let index = arguments.firstIndex(of: "--selftest"), arguments.count > index + 2,
              let pid = pid_t(arguments[index + 1]), let gain = Float(arguments[index + 2]) else { return false }
        run(targetPID: pid, gain: gain)
        return true
    }

    private static func run(targetPID: pid_t, gain: Float) {
        log("permission=\(AudioCapturePermission.status) raw=\(AudioCapturePermission.rawPreflight)")
        if AudioCapturePermission.status != .authorized {
            let done = DispatchSemaphore(value: 0)
            AudioCapturePermission.request { granted in
                log("request granted=\(granted)")
                done.signal()
            }
            while done.wait(timeout: .now() + 0.1) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        guard let outputUID = OutputDevice.defaultUID() else { return log("sem dispositivo de saída") }
        log("output=\(outputUID)")
        guard let target = AudioProcess.all().first(where: { $0.pid == targetPID }) else { return log("pid \(targetPID) sem objeto de áudio") }
        let ownObject = AudioProcess.ownObjectID()
        log("target object=\(target.objectID) playing=\(target.isPlaying) own object=\(String(describing: ownObject))")

        let rawMeter = ProcessTapEngine(processObjectIDs: [target.objectID], outputDeviceUID: outputUID, gain: 0, muteBehavior: .unmuted)
        let router = ProcessTapEngine(processObjectIDs: [target.objectID], outputDeviceUID: outputUID, gain: gain)
        do {
            try rawMeter.start()
            try router.start()
        } catch {
            return log("erro: \(error.localizedDescription)")
        }
        var ownMeter: ProcessTapEngine?
        if let ownObject = AudioProcess.ownObjectID() {
            let meter = ProcessTapEngine(processObjectIDs: [ownObject], outputDeviceUID: outputUID, gain: 0, muteBehavior: .unmuted)
            do { try meter.start(); ownMeter = meter } catch { log("medidor próprio: \(error.localizedDescription)") }
        }
        let seconds = CommandLine.arguments.firstIndex(of: "--seconds").flatMap { Double(CommandLine.arguments[$0 + 1]) } ?? 4
        for _ in 0..<Int(seconds * 2) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let raw = rawMeter.peakLevel
            let out = ownMeter?.peakLevel ?? -1
            log(String(format: "raw=%.4f routedInput=%.4f ownOutput=%.4f ratio=%.2f", raw, router.peakLevel, out, raw > 0 ? out / raw : -1))
        }
        router.stop()
        rawMeter.stop()
        ownMeter?.stop()
    }

    @MainActor
    private static func runModelTest(appID: String) {
        let suite = "com.marcelocunha.soundmanager.model-test"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!)
        model.requestPermissionIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let app = model.apps.first(where: { $0.id == appID }), let outputUID = OutputDevice.defaultUID() else { return log("app \(appID) não encontrado") }
        log("permission=\(model.permission) app=\(app.name) processes=\(app.audioProcessIDs.sorted())")

        var meters = ModelTestMeters(outputUID: outputUID)
        let script: [(Int, String, () -> Void)] = [
            (0, "volume 0%", { model.setVolume(0, for: app) }),
            (2, "volume 30%", { model.setVolume(0.3, for: app) }),
        ]
        for tick in 0..<16 {
            for (at, label, action) in script where at == tick {
                action()
                log("ação: \(label)")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let current = model.apps.first { $0.id == appID }
            meters.follow(current?.audioProcessIDs ?? [])
            let visible = model.audibleApps.contains { $0.id == appID }
            log(String(format: "t=%02d visível=%@ tocando=%@ raw=%.4f saída=%.4f razão=%.2f", tick, visible ? "sim" : "não", current?.isPlaying == true ? "sim" : "não", meters.raw, meters.output, meters.ratio))
        }
        model.setVolume(1, for: app)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        model.shutdown()
        meters.stop()
    }

    private static func listAudio() {
        for process in AudioProcess.all() {
            let responsible = ProcessLineage.responsiblePID(of: process.pid) ?? -1
            let parent = ProcessLineage.parentPID(of: process.pid) ?? -1
            print(process.pid, parent, responsible, process.bundleID ?? "-", process.isPlaying ? "playing" : "idle")
        }
    }

    private static func log(_ message: String) {
        let time = String(format: "%.1f", Date().timeIntervalSince1970)
        FileHandle.standardError.write(Data("selftest \(time): \(message)\n".utf8))
    }
}

extension AudioProcess {
    static func ownObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != .unknown ? object : nil
    }
}

private struct ModelTestMeters {
    let outputUID: String
    private var processIDs: Set<AudioObjectID> = []
    private var rawMeter: ProcessTapEngine?
    private var ownMeter: ProcessTapEngine?

    init(outputUID: String) {
        self.outputUID = outputUID
        if let own = AudioProcess.ownObjectID() {
            ownMeter = ProcessTapEngine(processObjectIDs: [own], outputDeviceUID: outputUID, gain: 0, muteBehavior: .unmuted)
            try? ownMeter?.start()
        }
    }

    var raw: Float { rawMeter?.peakLevel ?? 0 }
    var output: Float { ownMeter?.peakLevel ?? 0 }
    var ratio: Float { raw > 0 ? output / raw : -1 }

    mutating func follow(_ ids: Set<AudioObjectID>) {
        guard ids != processIDs else { return }
        processIDs = ids
        rawMeter?.stop()
        rawMeter = ids.isEmpty ? nil : ProcessTapEngine(processObjectIDs: ids, outputDeviceUID: outputUID, gain: 0, muteBehavior: .unmuted)
        try? rawMeter?.start()
    }

    func stop() {
        rawMeter?.stop()
        ownMeter?.stop()
    }
}
