import Foundation

struct ServerConnection: @unchecked Sendable {
    static let deviceNameLength = 64

    let video: TCPSocket
    let control: TCPSocket
    let deviceName: String

    // Forward tunnel (scrcpy 4.1): video socket first, then control; the server writes one dummy byte on the first socket once it accepted it.
    static func open(port: UInt16, attempts: Int = 100, shouldContinue: @escaping @Sendable () -> Bool) async throws -> ServerConnection {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try openBlocking(port: port, attempts: attempts, shouldContinue: shouldContinue) })
            }
        }
    }

    private static func openBlocking(port: UInt16, attempts: Int, shouldContinue: () -> Bool) throws -> ServerConnection {
        var video: TCPSocket?
        for _ in 0..<attempts {
            guard shouldContinue() else { throw SocketError(message: "Conexão cancelada.") }
            if let socket = try? TCPSocket.connectLocal(port: port), socket.readFully(count: 1) != nil {
                video = socket
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let video else { throw SocketError(message: "O servidor no celular não respondeu.") }
        let control = try TCPSocket.connectLocal(port: port)
        control.setNoDelay()
        guard let name = video.readFully(count: deviceNameLength) else {
            throw SocketError(message: "O celular fechou a conexão antes de enviar o nome.")
        }
        let deviceName = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
        return ServerConnection(video: video, control: control, deviceName: deviceName)
    }
}
