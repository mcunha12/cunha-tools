import Foundation

// State of the default output device as the ceiling for every app.
struct MasterLevel: Equatable {
    var volume: Double = 1
    var muted = false
    var hasHardwareVolume = true
    var hasHardwareMute = true
}

// The main volume caps each app; app volumes never move the main volume.
enum VolumeCeiling {
    static func effectiveVolume(_ appVolume: Double, ceiling: Double) -> Double {
        min(appVolume, ceiling)
    }

    static func storedVolume(dragged: Double, ceiling: Double) -> Double {
        min(max(dragged, 0), ceiling)
    }

    // Tap gain for one app; 1 means the app needs no tap.
    static func gain(app: VolumeSetting, master: MasterLevel, decibels: (Double) -> Double?) -> Float {
        if app.muted || app.volume <= 0 { return 0 }
        if master.muted && !master.hasHardwareMute { return 0 }
        let effective = effectiveVolume(app.volume, ceiling: master.volume)
        guard master.hasHardwareVolume else { return Float(min(max(effective, 0), 1)) }
        if master.volume <= 0 || app.volume >= master.volume { return 1 }
        guard let target = decibels(effective), let ceiling = decibels(master.volume) else {
            return Float(effective / master.volume)
        }
        return Float(min(pow(10, (target - ceiling) / 20), 1))
    }
}
