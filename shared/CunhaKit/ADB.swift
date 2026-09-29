import Foundation

public struct ADBDevice: Hashable, Sendable, Identifiable {
    public let serial: String
    public let state: String
    public let model: String?
    public let product: String?
    public let device: String?

    public var id: String { serial }
    public var isOnline: Bool { state == "device" }
    public var isWireless: Bool { serial.contains("._adb-tls-connect._tcp") || serial.contains(":") }
    public var displayName: String { (model ?? device ?? serial).replacingOccurrences(of: "_", with: " ") }
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

public struct ADBError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum ADB {
    public static let companionPackage = "com.marcelocunha.cunhatools"

    public static var candidatePaths: [String] {
        let home = NSHomeDirectory()
        var paths = [
            SuitePaths.platformTools.appendingPathComponent("adb").path,
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = ProcessInfo.processInfo.environment[key] { paths.append("\(sdk)/platform-tools/adb") }
        }
        return paths
    }

    public static var executableURL: URL? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    public static var isAvailable: Bool { executableURL != nil }

    public static func makeProcess(_ arguments: [String], serial: String? = nil) throws -> Process {
        guard let executableURL else { throw ADBError("adb não encontrado. Instale as ferramentas Android pelo Cunha Tools.") }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = (serial.map { ["-s", $0] } ?? []) + arguments
        return process
    }

    @discardableResult
    public static func run(_ arguments: [String], serial: String? = nil, timeout: TimeInterval = 30) async throws -> ProcessResult {
        try await runProcess(makeProcess(arguments, serial: serial), timeout: timeout)
    }

    public static func shell(_ command: String, serial: String? = nil, timeout: TimeInterval = 30) async throws -> ProcessResult {
        try await run(["shell", command], serial: serial, timeout: timeout)
    }

    public static func devices() async throws -> [ADBDevice] {
        let result = try await run(["devices", "-l"], timeout: 15)
        return parseDevices(result.output)
    }

    // USB first, then the first online wireless entry.
    public static func preferredDevice() async -> ADBDevice? {
        guard let devices = try? await devices() else { return nil }
        let online = devices.filter(\.isOnline)
        return online.first { !$0.isWireless } ?? online.first
    }

    public static func parseDevices(_ output: String) -> [ADBDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line -> ADBDevice? in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            var attributes: [String: String] = [:]
            for field in fields.dropFirst(2) {
                let parts = field.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { attributes[parts[0]] = parts[1] }
            }
            return ADBDevice(serial: fields[0], state: fields[1], model: attributes["model"], product: attributes["product"], device: attributes["device"])
        }
    }

    public static func isCompanionInstalled(serial: String) async -> Bool {
        guard let result = try? await shell("pm path \(companionPackage)", serial: serial, timeout: 15) else { return false }
        return result.output.contains("package:")
    }
}

public func runProcess(_ process: Process, timeout: TimeInterval = 30) async throws -> ProcessResult {
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    let collector = OutputCollector()
    stdout.fileHandleForReading.readabilityHandler = { collector.append(out: $0.availableData) }
    stderr.fileHandleForReading.readabilityHandler = { collector.append(err: $0.availableData) }
    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            collector.append(out: stdout.fileHandleForReading.readDataToEndOfFile())
            collector.append(err: stderr.fileHandleForReading.readDataToEndOfFile())
            let (out, err) = collector.snapshot()
            continuation.resume(returning: ProcessResult(status: finished.terminationStatus, stdout: out, stderr: err))
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(out data: Data) { lock.withLock { out.append(data) } }
    func append(err data: Data) { lock.withLock { err.append(data) } }
    func snapshot() -> (Data, Data) { lock.withLock { (out, err) } }
}
