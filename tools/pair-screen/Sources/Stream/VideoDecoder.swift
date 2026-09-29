import AVFoundation
import CoreMedia
import VideoToolbox

struct DecoderStats {
    var decodedFrames = 0
    var droppedFrames = 0
    var decodeErrors = 0
    var formatChanges = 0
    var hardware = false
}

// Hardware decode with VideoToolbox; decoded IOSurface frames go straight to the display layer's renderer.
final class VideoDecoder: @unchecked Sendable {
    let codec: VideoCodec
    private let renderer: AVSampleBufferVideoRenderer
    private var parameterSets: [[UInt8]] = []
    private var inputFormat: CMVideoFormatDescription?
    private var imageFormat: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKeyFrame = true

    private let lock = NSLock()
    private var statsStorage = DecoderStats()
    private var paused = false
    var onDecodeError: (() -> Void)?
    var onFrame: ((CVImageBuffer) -> Void)?

    init(codec: VideoCodec, renderer: AVSampleBufferVideoRenderer) {
        self.codec = codec
        self.renderer = renderer
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    var stats: DecoderStats { lock.withLock { statsStorage } }

    // Paused decoders drop packets; resuming waits for the next key frame.
    func setPaused(_ value: Bool) {
        lock.withLock {
            paused = value
            if !value { waitingForKeyFrame = true }
        }
    }

    func handleConfig(_ packet: UnsafeBufferPointer<UInt8>) {
        let sets = AnnexB.nalUnits(in: packet)
            .filter { codec.isParameterSet(codec.nalType(packet[$0.lowerBound])) }
            .map { Array(packet[$0]) }
        updateParameterSets(sets)
    }

    func handleFrame(_ packet: UnsafeBufferPointer<UInt8>, pts: UInt64, isKeyFrame: Bool) {
        let units = AnnexB.nalUnits(in: packet)
        var inlineSets: [[UInt8]] = []
        var payload: [Range<Int>] = []
        for unit in units {
            if codec.isParameterSet(codec.nalType(packet[unit.lowerBound])) {
                inlineSets.append(Array(packet[unit]))
            } else {
                payload.append(unit)
            }
        }
        if !inlineSets.isEmpty { updateParameterSets(merging: inlineSets) }

        let skip = lock.withLock { () -> Bool in
            if paused || (waitingForKeyFrame && !isKeyFrame) {
                statsStorage.droppedFrames += 1
                return true
            }
            waitingForKeyFrame = false
            return false
        }
        guard !skip, !payload.isEmpty, let format = inputFormat, let session = ensureSession(format: format),
              let sample = makeSampleBuffer(packet, units: payload, pts: pts, format: format) else { return }

        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, imageBuffer, presentation, _ in
            self?.didDecode(status: status, imageBuffer: imageBuffer, pts: presentation)
        }
        if status != noErr { failDecode() }
    }

    // Parameter sets repeated inside a frame replace the ones of the same NAL type.
    private func updateParameterSets(merging inline: [[UInt8]]) {
        var byType: [UInt8: [UInt8]] = [:]
        for set in parameterSets + inline { byType[codec.nalType(set[0])] = set }
        updateParameterSets(byType.keys.sorted().compactMap { byType[$0] })
    }

    private func updateParameterSets(_ sets: [[UInt8]]) {
        guard !sets.isEmpty, sets != parameterSets, let format = Self.makeFormat(codec: codec, parameterSets: sets) else { return }
        parameterSets = sets
        inputFormat = format
        if let session, !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
            VTDecompressionSessionInvalidate(session)
            self.session = nil
        }
        lock.withLock {
            statsStorage.formatChanges += 1
            waitingForKeyFrame = true
        }
    }

    private func ensureSession(format: CMVideoFormatDescription) -> VTDecompressionSession? {
        if let session { return session }
        let specification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: specification,
            imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &created
        )
        guard status == noErr, let created else {
            NSLog("PairScreen: VTDecompressionSessionCreate falhou: \(status)")
            failDecode()
            return nil
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        let hardware = Self.usesHardware(created)
        lock.withLock { statsStorage.hardware = hardware }
        session = created
        return created
    }

    // Annex-B start codes become 4-byte big-endian lengths, as VideoToolbox expects.
    private func makeSampleBuffer(_ packet: UnsafeBufferPointer<UInt8>, units: [Range<Int>], pts: UInt64, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        let total = units.reduce(0) { $0 + 4 + $1.count }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: total, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: total, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        let destination = UnsafeMutableRawPointer(pointer)
        var offset = 0
        for unit in units {
            let length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: length) { destination.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: 4) }
            destination.advanced(by: offset + 4).copyMemory(from: packet.baseAddress! + unit.lowerBound, byteCount: unit.count)
            offset += 4 + unit.count
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: CMTimeValue(pts), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = total
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    private func didDecode(status: OSStatus, imageBuffer: CVImageBuffer?, pts: CMTime) {
        guard status == noErr, let imageBuffer else {
            failDecode()
            return
        }
        if imageFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(imageFormat!, imageBuffer: imageBuffer) {
            var created: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: imageBuffer, formatDescriptionOut: &created)
            imageFormat = created
        }
        guard let imageFormat else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: imageBuffer, formatDescription: imageFormat, sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
        lock.withLock { statsStorage.decodedFrames += 1 }
        onFrame?(imageBuffer)
    }

    private func failDecode() {
        lock.withLock {
            statsStorage.decodeErrors += 1
            waitingForKeyFrame = true
        }
        onDecodeError?()
    }

    private static func usesHardware(_ session: VTDecompressionSession) -> Bool {
        let value = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        value.initialize(to: nil)
        defer {
            value.deinitialize(count: 1)
            value.deallocate()
        }
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: value)
        return value.pointee as? Bool ?? false
    }

    static func makeFormat(codec: VideoCodec, parameterSets: [[UInt8]]) -> CMVideoFormatDescription? {
        let joined = parameterSets.flatMap { $0 }
        let sizes = parameterSets.map(\.count)
        var format: CMVideoFormatDescription?
        let status = joined.withUnsafeBufferPointer { buffer -> OSStatus in
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(buffer.baseAddress! + offset)
                offset += size
            }
            switch codec {
            case .h265:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format
                )
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format
                )
            }
        }
        if status != noErr { NSLog("PairScreen: format description \(codec.label) falhou: \(status)") }
        return status == noErr ? format : nil
    }
}
