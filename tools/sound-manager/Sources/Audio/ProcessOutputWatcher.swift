import CoreAudio

// Calls back when any watched process starts or stops audio output.
@MainActor
final class ProcessOutputWatcher {
    private var observations: [AudioObjectID: PropertyObservation] = [:]
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func watch(_ processObjectIDs: Set<AudioObjectID>) {
        for id in observations.keys where !processObjectIDs.contains(id) {
            observations[id] = nil
        }
        for id in processObjectIDs where observations[id] == nil {
            observations[id] = PropertyObservation(id, kAudioProcessPropertyIsRunningOutput) { [weak self] in self?.onChange() }
        }
    }
}
