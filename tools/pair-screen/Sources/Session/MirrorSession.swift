import AVFoundation
import Foundation

enum SessionEnd: Equatable {
    case stopped
    case streamClosed
    case videoDisabled
    case configurationError
    case unsupportedCodec(UInt32)
}

struct SessionEvents {
    var onVideoSize: @MainActor (CGSize) -> Void
    var onClipboard: @MainActor (String) -> Void
    var onEnd: @MainActor (SessionEnd, _ receivedFrames: Int) -> Void
}

// One live connection to the scrcpy server: video socket (reader thread) and control socket (reader thread + writer queue).
final class MirrorSession: @unchecked Sendable {
    let deviceName: String
    private let video: TCPSocket
    private let control: TCPSocket
    private let renderer: AVSampleBufferVideoRenderer
    private let events: SessionEvents
    private let writeQueue = DispatchQueue(label: "pairscreen.control", qos: .userInteractive)

    private let lock = NSLock()
    private var decoderStorage: VideoDecoder?
    private var sizeStorage: (width: UInt16, height: UInt16) = (0, 0)
    private var lastData = Date()
    private var lastReset = Date.distantPast
    private var stopRequested = false
    private var videoPaused = false

    private static let headerSize = 12
    private static let flagSession: UInt8 = 0x80
    private static let flagConfig: UInt64 = 1 << 62
    private static let flagKeyFrame: UInt64 = 1 << 61
    private static let ptsMask: UInt64 = (1 << 61) - 1

    init(connection: ServerConnection, renderer: AVSampleBufferVideoRenderer, events: SessionEvents) {
        deviceName = connection.deviceName
        video = connection.video
        control = connection.control
        self.renderer = renderer
        self.events = events
    }

    var decoder: VideoDecoder? { lock.withLock { decoderStorage } }
    var secondsSinceLastData: TimeInterval { lock.withLock { Date().timeIntervalSince(lastData) } }

    // Device-side video size of the current capture session; touch positions are expressed in it.
    var videoSize: (width: UInt16, height: UInt16) { lock.withLock { sizeStorage } }

    func start() {
        let videoThread = Thread { [self] in runVideo() }
        videoThread.name = "pairscreen.video"
        videoThread.qualityOfService = .userInteractive
        videoThread.start()
        let controlThread = Thread { [self] in runDeviceMessages() }
        controlThread.name = "pairscreen.device-messages"
        controlThread.qualityOfService = .utility
        controlThread.start()
    }

    func stop() {
        lock.withLock { stopRequested = true }
        video.shutdown()
        control.shutdown()
    }

    func send(_ message: ControlMessage) {
        let bytes = message.serialized()
        writeQueue.async { [control] in _ = control.writeAll(bytes) }
    }

    func setVideoPaused(_ paused: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { videoPaused = paused }
            return videoPaused != paused
        }
        guard changed else { return }
        decoder?.setPaused(paused)
        if !paused { send(.resetVideo) }
    }

    private func runVideo() {
        let end = readVideoStream()
        let frames = decoder.map { $0.stats.decodedFrames + $0.stats.droppedFrames } ?? 0
        let reason = lock.withLock { stopRequested } ? .stopped : end
        control.shutdown()
        let events = events
        DispatchQueue.main.async { MainActor.assumeIsolated { events.onEnd(reason, frames) } }
    }

    private func readVideoStream() -> SessionEnd {
        guard let codecBytes = video.readFully(count: 4) else { return .streamClosed }
        let codecID = Self.u32(codecBytes, 0)
        if codecID == 0 { return .videoDisabled }
        if codecID == 1 { return .configurationError }
        guard let codec = VideoCodec(streamID: codecID) else { return .unsupportedCodec(codecID) }

        let decoder = VideoDecoder(codec: codec, renderer: renderer)
        decoder.onDecodeError = { [weak self] in self?.requestVideoReset() }
        lock.withLock {
            decoderStorage = decoder
            if videoPaused { decoder.setPaused(true) }
        }

        var header = [UInt8](repeating: 0, count: Self.headerSize)
        var capacity = 1 << 20
        var packet = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { packet.deallocate() }

        while true {
            guard header.withUnsafeMutableBytes({ video.readFully(into: $0.baseAddress!, count: Self.headerSize) }) else { return .streamClosed }
            lock.withLock { lastData = Date() }
            if header[0] & Self.flagSession != 0 {
                let width = Self.u32(header, 4)
                let height = Self.u32(header, 8)
                guard width > 0, height > 0, width <= 0xFFFF, height <= 0xFFFF else { return .streamClosed }
                lock.withLock { sizeStorage = (UInt16(width), UInt16(height)) }
                let events = events
                DispatchQueue.main.async { MainActor.assumeIsolated { events.onVideoSize(CGSize(width: Int(width), height: Int(height))) } }
                continue
            }
            let flags = UInt64(Self.u32(header, 0)) << 32 | UInt64(Self.u32(header, 4))
            let length = Int(Self.u32(header, 8))
            guard length > 0, length < 1 << 26 else { return .streamClosed }
            if length > capacity {
                packet.deallocate()
                capacity = length
                packet = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            }
            guard video.readFully(into: packet, count: length) else { return .streamClosed }
            let buffer = UnsafeBufferPointer(start: packet.assumingMemoryBound(to: UInt8.self), count: length)
            if flags & Self.flagConfig != 0 {
                decoder.handleConfig(buffer)
            } else {
                decoder.handleFrame(buffer, pts: flags & Self.ptsMask, isKeyFrame: flags & Self.flagKeyFrame != 0)
            }
        }
    }

    // A decode error asks the server for a fresh capture session (new config + key frame), at most once per second.
    private func requestVideoReset() {
        let allowed = lock.withLock { () -> Bool in
            guard Date().timeIntervalSince(lastReset) > 1 else { return false }
            lastReset = Date()
            return true
        }
        if allowed { send(.resetVideo) }
    }

    private func runDeviceMessages() {
        var pending: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { control.readSome(into: $0) }
            guard count > 0 else { return }
            pending += chunk[0..<count]
            var start = 0
            parsing: while true {
                switch DeviceMessage.parse(pending[start...]) {
                case let .message(message, consumed):
                    start += consumed
                    if case let .clipboard(text) = message {
                        let events = events
                        DispatchQueue.main.async { MainActor.assumeIsolated { events.onClipboard(text) } }
                    }
                case .incomplete:
                    break parsing
                case .invalid:
                    NSLog("PairScreen: mensagem do dispositivo desconhecida; canal de controle encerrado")
                    return
                }
            }
            if start > 0 { pending.removeFirst(start) }
            if pending.count > DeviceMessage.maxSize * 2 { return }
        }
    }

    static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }
}
