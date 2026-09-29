import CunhaKit
import Foundation

struct StreamOptions: Equatable {
    var codec: VideoCodec
    var maxSize: Int
    var maxFps: Int
    var bitRateMbps: Int
}

enum LaunchError: LocalizedError {
    case noDevice
    case missingServer
    case adb(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: "Nenhum celular conectado."
        case .missingServer: "scrcpy-server ausente no app. Reinstale o Pair Screen."
        case let .adb(message): message
        }
    }
}

protocol ServerLauncher: Sendable {
    func launch(options: StreamOptions, preferredSerial: String?) async throws -> LaunchedServer
}

// A started server: local port of the tunnel plus what is needed to tear it down.
final class LaunchedServer: @unchecked Sendable {
    let port: UInt16
    let serial: String?
    private let process: Process?
    private let log: LogBuffer
    private let lock = NSLock()
    private var forwardActive: Bool

    init(port: UInt16, serial: String?, process: Process?, log: LogBuffer = LogBuffer()) {
        self.port = port
        self.serial = serial
        self.process = process
        self.log = log
        forwardActive = serial != nil
    }

    var isAlive: Bool { process?.isRunning ?? true }
    var recentLog: String { log.text }

    func removeForward() async {
        guard let serial, lock.withLock({ () -> Bool in defer { forwardActive = false }; return forwardActive }) else { return }
        _ = try? await ADB.run(["forward", "--remove", "tcp:\(port)"], serial: serial, timeout: 5)
    }

    func stop() async {
        terminateProcess()
        await removeForward()
    }

    func terminateProcess() {
        if let process, process.isRunning { process.terminate() }
    }
}

final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 8 * 1024

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

struct AdbServerLauncher: ServerLauncher {
    static let serverVersion = "4.1"
    static let devicePath = "/data/local/tmp/pair-screen-server.jar"

    func launch(options: StreamOptions, preferredSerial: String?) async throws -> LaunchedServer {
        let devices = (try? await ADB.devices().filter(\.isOnline)) ?? []
        guard let device = devices.first(where: { $0.serial == preferredSerial }) ?? devices.first(where: { !$0.isWireless }) ?? devices.first else {
            throw LaunchError.noDevice
        }
        guard let server = Bundle.main.url(forResource: "scrcpy-server", withExtension: nil) else { throw LaunchError.missingServer }
        let serial = device.serial

        let push = try await ADB.run(["push", server.path, Self.devicePath], serial: serial, timeout: 60)
        guard push.succeeded else { throw LaunchError.adb("Falha ao enviar o servidor: \(push.errorOutput.trimmed)") }

        let scid = String(format: "%08x", UInt32.random(in: 0..<0x8000_0000))
        let forward = try await ADB.run(["forward", "tcp:0", "localabstract:scrcpy_\(scid)"], serial: serial, timeout: 10)
        guard forward.succeeded, let port = UInt16(forward.output.trimmed) else {
            throw LaunchError.adb("Falha ao abrir o túnel adb: \(forward.errorOutput.trimmed)")
        }

        let process = try ADB.makeProcess(["shell", "CLASSPATH=\(Self.devicePath)", "app_process", "/", "com.genymobile.scrcpy.Server"]
            + [Self.serverVersion] + Self.serverArguments(options: options, scid: scid), serial: serial)
        let log = LogBuffer()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { log.append(chunk) }
        }
        let launched = LaunchedServer(port: port, serial: serial, process: process, log: log)
        do {
            try process.run()
        } catch {
            await launched.removeForward()
            throw LaunchError.adb("Falha ao iniciar o servidor: \(error.localizedDescription)")
        }
        return launched
    }

    static func serverArguments(options: StreamOptions, scid: String) -> [String] {
        [
            "scid=\(scid)",
            "log_level=info",
            "tunnel_forward=true",
            "audio=false",
            "video_codec=\(options.codec.rawValue)",
            "max_size=\(options.maxSize)",
            "max_fps=\(options.maxFps)",
            "video_bit_rate=\(options.bitRateMbps * 1_000_000)",
        ]
    }
}

// Self-test path: a local fake server already listens on the port.
struct DirectLauncher: ServerLauncher {
    let port: UInt16

    func launch(options: StreamOptions, preferredSerial: String?) async throws -> LaunchedServer {
        LaunchedServer(port: port, serial: nil, process: nil)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
