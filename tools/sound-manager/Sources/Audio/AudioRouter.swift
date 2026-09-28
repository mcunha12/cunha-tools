import CoreAudio
import Foundation

struct RouteRequest {
    let key: String
    let processObjectIDs: Set<AudioObjectID>
    let gain: Float
    // An app with its own volume keeps its tap at unity gain, so raising the main volume only changes the gain.
    let keepsTap: Bool
}

@MainActor
final class AudioRouter {
    private static let unityTeardownDelay: TimeInterval = 2

    private var engines: [String: ProcessTapEngine] = [:]
    private var unitySince: [String: Date] = [:]
    private(set) var failures: [String: String] = [:]

    var activeKeys: Set<String> { Set(engines.keys) }

    func apply(_ requests: [RouteRequest]) {
        guard let outputUID = OutputDevice.defaultUID() else { return }
        let requested = Dictionary(requests.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        for (key, engine) in engines where requested[key] == nil {
            engine.stop()
            engines[key] = nil
            unitySince[key] = nil
        }

        for request in requests {
            if request.gain >= 1, !request.keepsTap, !keepAtUnity(request, outputUID: outputUID) {
                engines[request.key]?.stop()
                engines[request.key] = nil
                continue
            }
            if request.gain < 1 || request.keepsTap { unitySince[request.key] = nil }

            if let engine = engines[request.key], engine.processObjectIDs == request.processObjectIDs, engine.outputDeviceUID == outputUID {
                engine.setGain(request.gain)
                continue
            }
            engines[request.key]?.stop()
            let engine = ProcessTapEngine(processObjectIDs: request.processObjectIDs, outputDeviceUID: outputUID, gain: request.gain)
            do {
                try engine.start()
                engines[request.key] = engine
                failures[request.key] = nil
            } catch {
                engines[request.key] = nil
                failures[request.key] = error.localizedDescription
                NSLog("SoundManager: \(request.key): \(error.localizedDescription)")
            }
        }
    }

    func stopAll() {
        engines.values.forEach { $0.stop() }
        engines.removeAll()
    }

    private func keepAtUnity(_ request: RouteRequest, outputUID: String) -> Bool {
        guard let engine = engines[request.key], engine.outputDeviceUID == outputUID else { return false }
        let since = unitySince[request.key] ?? Date()
        unitySince[request.key] = since
        guard Date().timeIntervalSince(since) < Self.unityTeardownDelay else {
            unitySince[request.key] = nil
            return false
        }
        return true
    }
}
