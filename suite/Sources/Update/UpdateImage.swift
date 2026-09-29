import CunhaKit
import Foundation

// The release DMG: downloaded to the cache, mounted read-only on a hidden mount point, checked and detached.
enum UpdateImage {
    static let appName = "Cunha Tools.app"

    static var workFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cunha Tools/update", isDirectory: true)
    }

    static var downloadFile: URL { workFolder.appendingPathComponent(UpdateSource.assetName) }

    // hdiutil creates the mount point and removes it on detach.
    static func attach(_ dmg: URL) async throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("cunha-update-\(UUID().uuidString)", isDirectory: true)
        guard await succeeds("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path]) else {
            throw InstallError(message: "O \(UpdateSource.assetName) não abre. Tente de novo.")
        }
        return mount
    }

    static func detach(_ mount: URL) async {
        if await succeeds("/usr/bin/hdiutil", ["detach", mount.path]) { return }
        _ = await succeeds("/usr/bin/hdiutil", ["detach", "-force", mount.path])
    }

    // The suite in the DMG, accepted only with this app's bundle ID, the release version and a valid signature.
    static func suite(in mount: URL, version: String) async throws -> URL {
        let app = mount.appendingPathComponent(appName, isDirectory: true)
        guard let suite = ToolBundle(url: app) else {
            throw InstallError(message: "O \(UpdateSource.assetName) não tem o \(appName).")
        }
        guard suite.bundleID == Bundle.main.bundleIdentifier else {
            throw InstallError(message: "O \(appName) do DMG tem outro identificador: \(suite.bundleID).")
        }
        guard BundleVersion.compare(suite.version.short, version) == .orderedSame else {
            throw InstallError(message: "O DMG da versão \(version) traz o Cunha Tools \(suite.version.short).")
        }
        guard await isValidlySigned(app) else {
            throw InstallError(message: "A assinatura do \(appName) do DMG não confere.")
        }
        return app
    }

    static func isValidlySigned(_ app: URL) async -> Bool {
        await succeeds("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: workFolder)
    }

    private static func succeeds(_ tool: String, _ arguments: [String]) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        return (try? await runProcess(process, timeout: 120))?.succeeded == true
    }
}
