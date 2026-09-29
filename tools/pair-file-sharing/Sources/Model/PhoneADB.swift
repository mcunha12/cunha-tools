import CunhaKit
import Foundation

// Everything the Mac asks the phone over adb: provision a pairing, wake the service, read the Wi-Fi IP.
enum PhoneADB {
    static let service = "\(ADB.companionPackage)/.TransferService"

    struct Provisioned {
        let id: String
        let name: String
        let host: String?
    }

    static func provision(serial: String, key: Data, macID: String, macName: String, host: String?, port: UInt16) async throws -> Provisioned {
        let command = [
            "am broadcast -a \(ADB.companionPackage).PAIR -n \(ADB.companionPackage)/.PairReceiver --include-stopped-packages",
            "--es key \(quote(Base64URL.encode(key)))",
            "--es mac_name \(quote(macName))",
            "--es mac_id \(quote(macID))",
            "--es host \(quote(host ?? ""))",
            "--ei port \(port)",
        ].joined(separator: " ")
        let result = try await ADB.shell(command, serial: serial, timeout: 20)
        guard let data = result.output.range(of: #"data="([^"]*)""#, options: .regularExpression).map({ String(result.output[$0].dropFirst(6).dropLast()) }) else {
            throw TransferError("o celular não confirmou o pareamento")
        }
        let parts = data.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "ok" else { throw TransferError("o celular recusou o pareamento") }
        for permission in ["android.permission.WRITE_SECURE_SETTINGS", "android.permission.POST_NOTIFICATIONS"] {
            _ = try? await ADB.shell("pm grant \(ADB.companionPackage) \(permission)", serial: serial)
        }
        await wake(serial: serial)
        return Provisioned(id: parts[1], name: parts[2], host: await wifiAddress(serial: serial))
    }

    static func wake(serial: String) async {
        _ = try? await ADB.shell("am start-foreground-service -n \(service)", serial: serial, timeout: 10)
    }

    static func wifiAddress(serial: String) async -> String? {
        guard let result = try? await ADB.shell("ip -4 -o addr show wlan0", serial: serial, timeout: 10),
              let range = result.output.range(of: #"inet [0-9.]+"#, options: .regularExpression) else { return nil }
        return String(result.output[range].dropFirst(5))
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
