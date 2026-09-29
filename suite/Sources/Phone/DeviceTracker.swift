import CunhaKit
import Foundation

// One idle `adb track-devices -l` process: the adb server pushes every device change, so nothing polls.
@MainActor
final class DeviceTracker {
    private let onChange: @MainActor ([ADBDevice]) -> Void
    private var process: Process?
    private var buffer = Data()
    private var running = false
    private var retryDelay: Double = 1

    init(onChange: @escaping @MainActor ([ADBDevice]) -> Void) { self.onChange = onChange }

    func start() {
        running = true
        launch()
    }

    func stop() {
        running = false
        process?.terminate()
        process = nil
    }

    private func launch() {
        guard running, process == nil, let process = try? ADB.makeProcess(["track-devices", "-l"]) else { return }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(finished) } }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            scheduleRetry()
        }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        for devices in ADBOutput.takeTrackFrames(&buffer) {
            retryDelay = 1
            onChange(devices)
        }
    }

    private func exited(_ finished: Process) {
        guard finished === process else { return }
        process = nil
        buffer.removeAll()
        onChange([])
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard running else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
    }
}
