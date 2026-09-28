import Foundation

// Builds a downloaded source tree with its own scripts/build-suite.sh, as on the developer's Mac.
enum UpdateBuilder {
    static var workFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cunha Tools/update", isDirectory: true)
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Cunha Tools/update.log")
    }

    // xcode-select -p fails without Command Line Tools and, unlike xcrun, never opens the install dialog.
    static func hasToolchain() async -> Bool {
        (try? await run("/usr/bin/xcode-select", ["-p"])) != nil
    }

    static func extract(_ archive: URL, into folder: URL) async throws -> URL {
        let files = FileManager.default
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try await run("/usr/bin/tar", ["-xzf", archive.path, "-C", folder.path])
        let roots = (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let root = roots.first(where: { files.fileExists(atPath: $0.appendingPathComponent("scripts/build-suite.sh").path) }) else {
            throw InstallError(message: "O código baixado não tem scripts/build-suite.sh.")
        }
        return root
    }

    // Native architecture only: the update is for this Mac, and it halves the build time.
    static func build(source: URL, commit: String) async throws -> URL {
        var environment = ProcessInfo.processInfo.environment
        environment["ARCHS"] = nativeArchitecture
        environment["SCRATCH"] = source.appendingPathComponent(".build").path
        environment["CUNHA_SOURCE_COMMIT"] = commit
        let output: String
        do {
            output = try await run("/bin/zsh", [source.appendingPathComponent("scripts/build-suite.sh").path], environment: environment, log: logURL)
        } catch {
            throw InstallError(message: "O build falhou. O log está em \(logURL.path).")
        }
        let path = output.split(separator: "\n").last.map(String.init) ?? ""
        guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else {
            throw InstallError(message: "O build não gerou o Cunha Tools.app. O log está em \(logURL.path).")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func isValidlySigned(_ app: URL) async -> Bool {
        (try? await run("/usr/bin/codesign", ["--verify", "--strict", app.path])) != nil
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: workFolder)
    }

    private static var nativeArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    // Returns stdout; stderr goes to the log when given. Throws on a non-zero exit.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil, log: URL? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        if let log {
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: log)
        } else {
            process.standardError = FileHandle.nullDevice
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard status == 0 else { throw InstallError(message: "\(tool) saiu com código \(status).") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
