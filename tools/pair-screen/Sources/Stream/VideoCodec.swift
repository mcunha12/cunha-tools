import CoreMedia

enum VideoCodec: String, CaseIterable, Identifiable {
    case h265
    case h264

    var id: String { rawValue }
    var label: String { self == .h265 ? "H.265" : "H.264" }

    // Codec ids sent by the server: "h264" / "h265" in ASCII.
    var streamID: UInt32 { self == .h265 ? 0x6832_3635 : 0x6832_3634 }
    var mediaType: CMVideoCodecType { self == .h265 ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264 }

    init?(streamID: UInt32) {
        guard let codec = Self.allCases.first(where: { $0.streamID == streamID }) else { return nil }
        self = codec
    }

    func nalType(_ header: UInt8) -> UInt8 {
        self == .h265 ? (header >> 1) & 0x3F : header & 0x1F
    }

    // H.265: VPS 32, SPS 33, PPS 34. H.264: SPS 7, PPS 8.
    func isParameterSet(_ type: UInt8) -> Bool {
        self == .h265 ? (32...34).contains(type) : type == 7 || type == 8
    }
}

enum AnnexB {
    // Payload ranges of every NAL unit in an Annex-B buffer (start codes and trailing zeros removed).
    static func nalUnits(in bytes: UnsafeBufferPointer<UInt8>) -> [Range<Int>] {
        let count = bytes.count
        var starts: [(code: Int, data: Int)] = []
        var i = 0
        while i + 2 < count {
            if bytes[i + 2] > 1 {
                i += 3
            } else if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i > 0 && bytes[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Range<Int>] = []
        units.reserveCapacity(starts.count)
        for (index, start) in starts.enumerated() {
            var end = index + 1 < starts.count ? starts[index + 1].code : count
            while end > start.data, bytes[end - 1] == 0 { end -= 1 }
            if end > start.data { units.append(start.data..<end) }
        }
        return units
    }
}
