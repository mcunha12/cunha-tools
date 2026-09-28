import Foundation

struct VolumeSetting: Codable, Equatable {
    var volume: Double = 1
    var muted = false

    var isDefault: Bool { volume >= 1 && !muted }
}

// Volume and mute per key (app id or device UID), saved in UserDefaults.
struct VolumeSettingsStore {
    static let appsKey = "appVolumeSettings"
    static let softwareMasterKey = "softwareMasterVolume"

    private let defaults: UserDefaults
    private let key: String
    private(set) var values: [String: VolumeSetting]

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
        values = Self.load(defaults, key: key)
    }

    // Re-reads before each write, so another instance on the same key keeps its entries.
    subscript(id: String) -> VolumeSetting {
        get { values[id] ?? VolumeSetting() }
        set {
            values = Self.load(defaults, key: key)
            values[id] = newValue.isDefault ? nil : newValue
            save()
        }
    }

    private static func load(_ defaults: UserDefaults, key: String) -> [String: VolumeSetting] {
        let data = defaults.data(forKey: key)
        return data.flatMap { try? JSONDecoder().decode([String: VolumeSetting].self, from: $0) } ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }
}
