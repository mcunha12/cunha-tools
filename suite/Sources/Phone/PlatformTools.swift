import CunhaKit
import Foundation

// Google's platform-tools zip, extracted so that <destination>/adb exists.
enum PlatformTools {
    static let downloadURL = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip")!

    @MainActor
    static func install(into destination: URL = SuitePaths.platformTools, progress: @escaping @MainActor (Double) -> Void) async throws {
        let observer = DownloadProgress(progress)
        let (download, response) = try await URLSession.shared.download(from: downloadURL, delegate: observer)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ADBError("Download falhou (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        try await Task.detached(priority: .userInitiated) { try extract(download, into: destination) }.value
    }

    private static func extract(_ zip: URL, into destination: URL) throws {
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".platform-tools-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: staging) }
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        let extracted = staging.appendingPathComponent("platform-tools", isDirectory: true)
        guard ditto.terminationStatus == 0, files.isExecutableFile(atPath: extracted.appendingPathComponent("adb").path) else {
            throw ADBError("O arquivo baixado não tem o adb.")
        }
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: extracted, to: destination)
    }
}

private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @MainActor (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ report: @escaping @MainActor (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [report] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in report(value) }
        }
    }
}
