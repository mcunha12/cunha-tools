import Foundation

// Listener: authenticates each connection, then serves INFO, OFFER (new transfer) or JOIN (extra connection).
final class TransferServer: @unchecked Sendable {
    struct Events {
        var peer: @Sendable (PeerInfo) -> Void = { _ in }
        var started: @Sendable (ReceiveSession) -> Void = { _ in }
        var ended: @Sendable (ReceiveSession, String?) -> Void = { _, _ in }
    }

    let role: UInt8
    let id: String
    let name: String
    private let requestedPort: UInt16
    private let sink: FolderSink
    private let keys: @Sendable (Data) -> Data?
    private let events: Events
    private let lock = NSLock()
    private var sessions: [String: ReceiveSession] = [:]
    private var listener: TCPListener?

    init(port: UInt16, role: UInt8, id: String, name: String, sink: FolderSink, keys: @escaping @Sendable (Data) -> Data?, events: Events) {
        requestedPort = port
        self.role = role
        self.id = id
        self.name = name
        self.sink = sink
        self.keys = keys
        self.events = events
    }

    var port: UInt16 { lock.withLock { listener?.port } ?? requestedPort }

    func start() throws {
        let listener = try TCPListener(port: requestedPort)
        lock.withLock { self.listener = listener }
        let thread = Thread { [self] in
            while let socket = listener.accept() {
                let worker = Thread { [self] in handle(socket) }
                worker.name = "pfs-conn"
                worker.start()
            }
        }
        thread.name = "pfs-accept"
        thread.start()
    }

    func stop() {
        let (listener, open) = lock.withLock { (self.listener, Array(sessions.values)) }
        listener?.stop()
        open.forEach { $0.fail("serviço encerrado") }
    }

    var activeSessions: [ReceiveSession] { lock.withLock { Array(sessions.values) } }

    private func handle(_ socket: TCPSocket) {
        defer { socket.close() }
        do {
            let channel = try SecureChannel.accept(socket: socket, role: role, lookup: keys)
            guard let first = try channel.receive(), let typeByte = first.first else { return }
            switch MessageType(rawValue: typeByte) {
            case .info: try info(channel, first)
            case .offer: try offer(channel, first)
            case .join: try join(channel, first)
            default: throw TransferError("mensagem inesperada")
            }
        } catch {
            // A failed connection only matters through its session, which records the reason.
        }
    }

    private func info(_ channel: SecureChannel, _ frame: Data) throws {
        var reader = ByteReader(frame)
        _ = try reader.u8()
        let peer = PeerInfo(id: try reader.string(), name: try reader.string(), host: channel.remoteHost, port: try reader.u16(), keyID: channel.keyID)
        var out = ByteWriter(.info)
        try out.string(id)
        try out.string(name)
        out.u16(port)
        try channel.send(out)
        events.peer(peer)
    }

    private func offer(_ channel: SecureChannel, _ frame: Data) throws {
        var reader = ByteReader(frame)
        _ = try reader.u8()
        let sessionID = try reader.raw(16).map { String(format: "%02x", $0) }.joined()
        _ = try reader.u8()
        let peerID = try reader.string()
        let peerName = try reader.string()
        let count = Int(try reader.u32())
        let total = Int64(try reader.u64())
        guard count > 0, count <= 1_000_000, total >= 0 else { throw TransferError("manifesto inválido") }
        var entries: [IncomingEntry] = []
        entries.reserveCapacity(count)
        var sum: Int64 = 0
        var taken = Set<String>()
        while true {
            let inFrame = Int(try reader.u32())
            for _ in 0..<inFrame where entries.count < count {
                let isDirectory = try reader.u8() == 1
                let path = RelativePath.unique(try RelativePath.clean(try reader.string()), taken: &taken, isDirectory: isDirectory)
                let size = Int64(bitPattern: try reader.u64())
                let modified = Int64(bitPattern: try reader.u64())
                guard size >= 0 else { throw TransferError("tamanho inválido") }
                entries.append(IncomingEntry(path: path, size: isDirectory ? 0 : size, modifiedMillis: modified, isDirectory: isDirectory))
                sum += isDirectory ? 0 : size
            }
            if entries.count >= count { break }
            guard let next = try channel.receive(), next.first == MessageType.offerMore.rawValue else { throw TransferError("manifesto incompleto") }
            reader = ByteReader(next)
            _ = try reader.u8()
        }
        guard sum == total else { throw TransferError("manifesto inconsistente") }
        let peer = PeerInfo(id: peerID, name: peerName, host: channel.remoteHost, port: 0, keyID: channel.keyID)
        events.peer(peer)
        let space = sink.usableSpace()
        if space >= 0 && space < total {
            try reject(channel, "sem espaço no destino")
            return
        }
        let sink = self.sink
        let ended = events.ended
        let session = ReceiveSession(id: sessionID, peer: peer, entries: entries, total: total, sink: sink) { session, error in
            ended(session, error)
            sink.forget(session: session.id)
        }
        lock.withLock { sessions[sessionID] = session }
        defer { _ = lock.withLock { sessions.removeValue(forKey: sessionID) } }
        do {
            try session.attach(channel)
            try channel.send(ByteWriter(.accept))
            events.started(session)
            try receive(channel, session: session, isControl: true)
        } catch {
            session.fail(error.localizedDescription)
            throw error
        }
    }

    private func join(_ channel: SecureChannel, _ frame: Data) throws {
        var reader = ByteReader(frame)
        _ = try reader.u8()
        let sessionID = try reader.raw(16).map { String(format: "%02x", $0) }.joined()
        guard let session = lock.withLock({ sessions[sessionID] }), !session.isEnded else {
            try reject(channel, "transferência desconhecida")
            return
        }
        do {
            try session.attach(channel)
            try channel.send(ByteWriter(.accept))
            try receive(channel, session: session, isControl: false)
        } catch {
            session.fail(error.localizedDescription)
            throw error
        }
    }

    private func receive(_ channel: SecureChannel, session: ReceiveSession, isControl: Bool) throws {
        while true {
            guard let frame = try channel.receive() else {
                if isControl { throw TransferError("o remetente encerrou a conexão") }
                return
            }
            switch frame.first.flatMap(MessageType.init(rawValue:)) {
            case .data:
                try session.write(frame)
            case .finish where isControl:
                do {
                    try session.complete()
                } catch {
                    try? reject(channel, error.localizedDescription)
                    throw error
                }
                var out = ByteWriter(.done)
                out.u32(UInt32(session.entries.count))
                out.u64(UInt64(session.total))
                try channel.send(out)
                return
            case .cancel:
                throw TransferError("cancelado pelo remetente")
            default:
                throw TransferError("mensagem inesperada")
            }
        }
    }

    private func reject(_ channel: SecureChannel, _ reason: String) throws {
        var out = ByteWriter(.reject)
        try out.string(reason)
        try channel.send(out)
    }
}
