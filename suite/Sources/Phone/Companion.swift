import CunhaKit
import Foundation

// The Android companion app shipped inside the suite at Contents/Resources/Android.
enum Companion {
    static let package = ADB.companionPackage
    static let autoBlockerHint = "No Samsung, desligue Configurações → Segurança e privacidade → Bloqueador automático. Se o Play Protect perguntar, toque em \"Instalar mesmo assim\"."

    static var apkURL: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Android/cunha-companion.apk"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func installedVersion(serial: String) async -> String? {
        guard let result = try? await ADB.shell("dumpsys package \(package)", serial: serial, timeout: 15) else { return nil }
        return ADBOutput.versionName(dumpsys: result.output, package: package)
    }

    static func install(apk: URL, serial: String) async throws {
        let install = try await ADB.run(["install", "-r", apk.path], serial: serial, timeout: 180)
        let output = install.output + install.errorOutput
        guard install.succeeded, output.contains("Success") else {
            let reason = lastLine(output)
            throw ADBError(ADBOutput.installBlocked(output) ? "Instalação bloqueada no celular (\(reason)). \(autoBlockerHint)" : "Falha ao instalar: \(reason)")
        }
        let secure = try await ADB.shell("pm grant \(package) android.permission.WRITE_SECURE_SETTINGS", serial: serial)
        let secureOutput = (secure.output + secure.errorOutput).lowercased()
        guard secure.succeeded, !secureOutput.contains("exception"), !secureOutput.contains("error") else {
            throw ADBError("App instalado, mas a permissão WRITE_SECURE_SETTINGS falhou: \(lastLine(secure.output + secure.errorOutput))")
        }
        // Android 12 and older have no POST_NOTIFICATIONS; a failure there is expected.
        _ = try? await ADB.shell("pm grant \(package) android.permission.POST_NOTIFICATIONS", serial: serial)
        try await launch(serial: serial)
    }

    private static func launch(serial: String) async throws {
        let resolved = try await ADB.shell("cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER \(package)", serial: serial)
        if let component = resolved.output.split(whereSeparator: \.isNewline).last.map(String.init), component.contains("/") {
            let start = try await ADB.shell("am start -n \(component.trimmingCharacters(in: .whitespaces))", serial: serial)
            if start.succeeded, !start.output.contains("Error") { return }
        }
        _ = try await ADB.shell("monkey -p \(package) -c android.intent.category.LAUNCHER 1", serial: serial)
    }

    private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "sem resposta do adb"
    }
}
