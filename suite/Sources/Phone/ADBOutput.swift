import CunhaKit
import Foundation

// Parsers for adb's text output, kept pure so --selftest-phone can check them.
enum ADBOutput {
    static func pairSucceeded(_ output: String) -> Bool { output.contains("Successfully paired") }

    // "Successfully paired to 192.168.0.10:37891 [guid=adb-R5CT-AbCd]" → adb-R5CT-AbCd, the connect service name.
    static func pairedGUID(_ output: String) -> String? {
        guard let range = output.range(of: #"guid=([^\]\s]+)"#, options: .regularExpression) else { return nil }
        return String(output[range].dropFirst("guid=".count))
    }

    static func connectSucceeded(_ output: String) -> Bool {
        let text = output.lowercased()
        return text.contains("connected to") && !text.contains("failed") && !text.contains("cannot")
    }

    // Reads versionName inside the "Package [<package>]" block; no block means not installed.
    static func versionName(dumpsys: String, package: String) -> String? {
        var inPackage = false
        for line in dumpsys.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Package [") { inPackage = trimmed.hasPrefix("Package [\(package)]") }
            if inPackage, trimmed.hasPrefix("versionName=") { return String(trimmed.dropFirst("versionName=".count)) }
        }
        return nil
    }

    static func installBlocked(_ output: String) -> Bool {
        let text = output.lowercased()
        return ["install_failed_user_restricted", "install_failed_verification_failure", "play protect", "blocked", "bloque"].contains { text.contains($0) }
    }

    // `adb track-devices -l` frames: 4 hex digits with the payload length, then a `devices -l` listing.
    static func takeTrackFrames(_ buffer: inout Data) -> [[ADBDevice]] {
        var frames: [[ADBDevice]] = []
        while buffer.count >= 4 {
            let header = String(decoding: buffer.prefix(4), as: UTF8.self)
            guard let length = Int(header, radix: 16) else {
                buffer.removeAll()
                break
            }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer = Data(buffer.dropFirst(4 + length))
            frames.append(ADB.parseDevices(String(decoding: payload, as: UTF8.self)))
        }
        return frames
    }
}
