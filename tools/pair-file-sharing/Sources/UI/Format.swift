import Foundation

enum Format {
    private static let locale = Locale(identifier: "pt_BR")

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        (bytesPerSecond / 1e6).formatted(.number.precision(.fractionLength(bytesPerSecond < 10e6 ? 1 : 0)).locale(locale)) + " MB/s"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 10 { return seconds.formatted(.number.precision(.fractionLength(1)).locale(locale)) + " s" }
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        let minutes = Int(seconds / 60)
        return "\(minutes) min \(Int(seconds) % 60) s"
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted(.number.locale(locale))) itens"
    }
}
