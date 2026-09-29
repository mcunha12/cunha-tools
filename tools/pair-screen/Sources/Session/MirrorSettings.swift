import Foundation

@MainActor
final class MirrorSettings: ObservableObject {
    static let maxSizeChoices = [1024, 1280, 1600, 1920, 2560, 0]
    static let fpsChoices = [30, 60, 90, 120]
    static let bitRateChoices = [4, 8, 12, 16, 24, 32]

    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    @Published var maxSize: Int { didSet { save(maxSize, "maxSize") } }
    @Published var maxFps: Int { didSet { save(maxFps, "maxFps") } }
    @Published var bitRateMbps: Int { didSet { save(bitRateMbps, "bitRateMbps") } }
    @Published var codec: VideoCodec { didSet { save(codec.rawValue, "codec") } }
    @Published var turnScreenOff: Bool { didSet { save(turnScreenOff, "turnScreenOff") } }
    @Published var alwaysOnTop: Bool { didSet { save(alwaysOnTop, "alwaysOnTop") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        maxSize = defaults.object(forKey: "maxSize") as? Int ?? 1600
        maxFps = defaults.object(forKey: "maxFps") as? Int ?? 60
        bitRateMbps = defaults.object(forKey: "bitRateMbps") as? Int ?? 12
        codec = defaults.string(forKey: "codec").flatMap(VideoCodec.init(rawValue:)) ?? .h265
        turnScreenOff = defaults.object(forKey: "turnScreenOff") as? Bool ?? false
        alwaysOnTop = defaults.object(forKey: "alwaysOnTop") as? Bool ?? true
    }

    var streamOptions: StreamOptions {
        StreamOptions(codec: codec, maxSize: maxSize, maxFps: maxFps, bitRateMbps: bitRateMbps)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange?()
    }
}
