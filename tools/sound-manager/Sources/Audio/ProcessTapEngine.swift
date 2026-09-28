import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

final class ProcessTapEngine {
    let processObjectIDs: Set<AudioObjectID>
    let outputDeviceUID: String

    private let muteBehavior: CATapMuteBehavior
    private let renderer: TapRenderer
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?

    init(processObjectIDs: Set<AudioObjectID>, outputDeviceUID: String, gain: Float, muteBehavior: CATapMuteBehavior = .mutedWhenTapped) {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
        self.muteBehavior = muteBehavior
        self.renderer = TapRenderer(gain: gain)
    }

    var peakLevel: Float { renderer.peakLevel }

    func setGain(_ gain: Float) {
        renderer.targetGain = gain
    }

    func start() throws {
        do {
            try createTap()
            try createAggregateDevice()
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != .unknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    deinit {
        stop()
    }

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processObjectIDs))
        description.uuid = UUID()
        description.name = "Sound Manager"
        description.muteBehavior = muteBehavior
        description.isPrivate = true
        var tap = AudioObjectID.unknown
        try checkStatus(AudioHardwareCreateProcessTap(description, &tap), "Criar tap de processo")
        tapID = tap
        let format: AudioStreamBasicDescription = tap.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        renderer.tapIsInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }

    private func createAggregateDevice() throws {
        guard let tapUID = tapID.readString(kAudioTapPropertyUID) else {
            throw CoreAudioError(operation: "Ler UID do tap", status: kAudioHardwareUnspecifiedError)
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sound Manager",
            kAudioAggregateDeviceUIDKey: "SoundManager-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregate = AudioObjectID.unknown
        try checkStatus(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate), "Criar dispositivo agregado")
        aggregateID = aggregate
    }

    private func startIO() throws {
        let renderer = renderer
        try checkStatus(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
                renderer.render(input: input, output: output)
            },
            "Criar IOProc"
        )
        try checkStatus(AudioDeviceStart(aggregateID, ioProcID), "Iniciar áudio")
    }
}

final class TapRenderer: @unchecked Sendable {
    private let target: Atomic<UInt32>
    private let peak = Atomic<UInt32>(0)
    private var currentGain: Float
    var tapIsInterleaved = true

    init(gain: Float) {
        target = Atomic(gain.bitPattern)
        currentGain = gain
    }

    var targetGain: Float {
        get { Float(bitPattern: target.load(ordering: .relaxed)) }
        set { target.store(newValue.bitPattern, ordering: .relaxed) }
    }

    var peakLevel: Float { Float(bitPattern: peak.load(ordering: .relaxed)) }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let source = tapSource(inputs)
        let goal = targetGain
        let totalOutputChannels = outputs.reduce(0) { $0 + Int($1.mNumberChannels) }
        var bufferPeak: Float = 0
        var channelOffset = 0

        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let step = frames > 0 ? (goal - currentGain) / Float(frames) : 0
            for frame in 0..<frames {
                let gain = currentGain + step * Float(frame)
                let (left, right) = source?.sample(at: frame) ?? (0, 0)
                for channel in 0..<channels {
                    let outputChannel = channelOffset + channel
                    let sample: Float
                    if totalOutputChannels == 1 {
                        sample = (left + right) * 0.5
                    } else if outputChannel == 0 {
                        sample = left
                    } else if outputChannel == 1 {
                        sample = right
                    } else {
                        sample = 0
                    }
                    data[frame * channels + channel] = sample * gain
                }
                bufferPeak = max(bufferPeak, abs(left), abs(right))
            }
            channelOffset += channels
        }
        currentGain = goal
        peak.store(bufferPeak.bitPattern, ordering: .relaxed)
    }

    private func tapSource(_ inputs: UnsafeMutableAudioBufferListPointer) -> TapSource? {
        guard let last = inputs.last, let lastData = last.mData?.assumingMemoryBound(to: Float.self) else { return nil }
        if tapIsInterleaved || inputs.count < 2 {
            let channels = max(Int(last.mNumberChannels), 1)
            let frames = Int(last.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            return TapSource(left: lastData, right: channels > 1 ? lastData + 1 : lastData, stride: channels, frames: frames)
        }
        let previous = inputs[inputs.count - 2]
        guard let leftData = previous.mData?.assumingMemoryBound(to: Float.self) else { return nil }
        let frames = Int(min(previous.mDataByteSize, last.mDataByteSize)) / MemoryLayout<Float>.size
        return TapSource(left: leftData, right: lastData, stride: 1, frames: frames)
    }
}

private struct TapSource {
    let left: UnsafePointer<Float>
    let right: UnsafePointer<Float>
    let stride: Int
    let frames: Int

    func sample(at frame: Int) -> (Float, Float) {
        guard frame < frames else { return (0, 0) }
        return (left[frame * stride], right[frame * stride])
    }
}
