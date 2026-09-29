import Darwin
import Foundation
import Synchronization

struct OutgoingItem: Sendable {
    let path: String
    let relativePath: String
    let size: Int64
    let modifiedMillis: Int64
    let isDirectory: Bool

    var encodedSize: Int { 1 + ByteWriter.stringSize(relativePath) + 16 }

    // Dropped files and folders; folders expand recursively, empty folders stay as entries, symlinks inside folders are skipped.
    static func collect(_ urls: [URL]) -> [OutgoingItem] {
        var items: [OutgoingItem] = []
        for url in urls { add(url.standardizedFileURL, relative: url.lastPathComponent, root: true, into: &items) }
        return items
    }

    private static func add(_ url: URL, relative: String, root: Bool, into items: inout [OutgoingItem]) {
        guard url.lastPathComponent != ".DS_Store" else { return }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }
        if values.isSymbolicLink == true && !root { return }
        let modified = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)
        let isDirectory = values.isDirectory == true || (root && (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        if !isDirectory {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? Int64(values.fileSize ?? 0)
            items.append(OutgoingItem(path: url.path, relativePath: relative, size: size, modifiedMillis: modified, isDirectory: false))
            return
        }
        let children = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.lastPathComponent != ".DS_Store" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if children.isEmpty {
            items.append(OutgoingItem(path: url.path, relativePath: relative, size: 0, modifiedMillis: modified, isDirectory: true))
            return
        }
        for child in children { add(child, relative: relative + "/" + child.lastPathComponent, root: false, into: &items) }
    }
}

struct PeerInfo: Sendable {
    let id: String
    let name: String
    let host: String?
    let port: UInt16
    let keyID: Data
}

struct SendResult: Sendable {
    let files: Int
    let bytes: Int64
    let seconds: Double
    var megabytesPerSecond: Double { seconds > 0 ? Double(bytes) / seconds / 1e6 : 0 }
}

// The first connection failed, so the caller may try another address.
struct ConnectError: LocalizedError {
    let underlying: Error
    var errorDescription: String? { underlying.localizedDescription }
}

// Sends a file set over N parallel connections; 8 MiB blocks of the concatenated stream go to whichever connection is free.
final class TransferSender: @unchecked Sendable {
    let key: Data
    let role: UInt8
    let id: String
    let name: String
    var connectTimeout: TimeInterval = 2
    private let sentBytes = Atomic<Int64>(0)
    private let nextBlock = Atomic<Int>(0)
    private let lock = NSLock()
    private var channels: [SecureChannel] = []
    private var failure: Error?
    private var cancelled = false
    private(set) var total: Int64 = 0

    init(key: Data, role: UInt8, id: String, name: String) {
        self.key = key
        self.role = role
        self.id = id
        self.name = name
    }

    var sent: Int64 { sentBytes.load(ordering: .relaxed) }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let open = lock.withLock { () -> [SecureChannel] in
            cancelled = true
            return channels
        }
        open.forEach { $0.abort() }
    }

    static func info(host: String, port: UInt16, timeout: TimeInterval, key: Data, role: UInt8, id: String, name: String, listenPort: UInt16) throws -> PeerInfo {
        let channel = try SecureChannel.connect(host: host, port: port, timeout: timeout, key: key, role: role)
        defer { channel.close() }
        var out = ByteWriter(.info)
        try out.string(id)
        try out.string(name)
        out.u16(listenPort)
        try channel.send(out)
        guard let reply = try channel.receive() else { throw TransferError("o destino não respondeu") }
        var reader = ByteReader(reply)
        guard try reader.u8() == MessageType.info.rawValue else { throw TransferError("resposta inesperada") }
        return PeerInfo(id: try reader.string(), name: try reader.string(), host: channel.remoteHost, port: try reader.u16(), keyID: channel.keyID)
    }

    func send(host: String, port: UInt16, items: [OutgoingItem], connections: Int = Wire.connections) throws -> SendResult {
        guard !items.isEmpty else { throw TransferError("nada para enviar") }
        let started = Date()
        let plan = Plan(items)
        total = plan.total
        let control: SecureChannel
        do {
            control = try open(host: host, port: port)
        } catch {
            throw ConnectError(underlying: error)
        }
        defer { closeAll() }
        do {
            let session = SecureChannel.randomBytes(16)
            try offer(control, session: session, plan: plan, connections: connections)
            try expectAccept(control)
            let workers = max(1, min(connections, plan.blocks))
            let group = DispatchGroup()
            for index in 1..<max(workers, 1) {
                group.enter()
                let thread = Thread { [self] in
                    joinAndWork(host: host, port: port, session: session, plan: plan)
                    group.leave()
                }
                thread.name = "pfs-send-\(index)"
                thread.start()
            }
            do { try work(control, plan: plan) } catch { fail(error) }
            group.wait()
            try throwIfFailed()
            try control.send(ByteWriter(.finish))
            guard let reply = try control.receive() else { throw TransferError("o destino encerrou antes de confirmar") }
            var reader = ByteReader(reply)
            let type = try reader.u8()
            if type == MessageType.reject.rawValue { throw TransferError(try reader.string()) }
            guard type == MessageType.done.rawValue else { throw TransferError("resposta inesperada") }
            let files = Int(try reader.u32())
            let bytes = Int64(try reader.u64())
            return SendResult(files: files, bytes: bytes, seconds: Date().timeIntervalSince(started))
        } catch {
            if isCancelled {
                try? control.send(ByteWriter(.cancel))
                throw TransferError("cancelado")
            }
            throw lock.withLock { failure } ?? error
        }
    }

    private func open(host: String, port: UInt16) throws -> SecureChannel {
        guard !isCancelled else { throw TransferError("cancelado") }
        let channel = try SecureChannel.connect(host: host, port: port, timeout: connectTimeout, key: key, role: role)
        let cancelledNow = lock.withLock { () -> Bool in
            channels.append(channel)
            return cancelled
        }
        if cancelledNow { channel.abort() }
        return channel
    }

    private func closeAll() {
        let open = lock.withLock { () -> [SecureChannel] in
            defer { channels.removeAll() }
            return channels
        }
        for channel in open {
            channel.abort()
            channel.close()
        }
    }

    private func offer(_ channel: SecureChannel, session: Data, plan: Plan, connections: Int) throws {
        var out = ByteWriter(.offer)
        out.raw(session)
        out.u8(UInt8(min(connections, 255)))
        try out.string(id)
        try out.string(name)
        out.u32(UInt32(plan.items.count))
        out.u64(UInt64(plan.total))
        var index = 0
        repeat {
            let countAt = out.count
            out.u32(0)
            var count = 0
            while index < plan.items.count, out.count + plan.items[index].encodedSize <= Wire.maxPlain {
                let item = plan.items[index]
                out.u8(item.isDirectory ? 1 : 0)
                try out.string(item.relativePath)
                out.u64(UInt64(item.size))
                out.u64(UInt64(bitPattern: item.modifiedMillis))
                index += 1
                count += 1
            }
            guard count > 0 || index == plan.items.count else { throw TransferError("nome de arquivo longo demais") }
            out.setU32(UInt32(count), at: countAt)
            try channel.send(out)
            out = ByteWriter(.offerMore)
        } while index < plan.items.count
    }

    private func expectAccept(_ channel: SecureChannel) throws {
        guard let reply = try channel.receive() else { throw TransferError("o destino recusou a conexão") }
        var reader = ByteReader(reply)
        let type = try reader.u8()
        if type == MessageType.reject.rawValue { throw TransferError(try reader.string()) }
        guard type == MessageType.accept.rawValue else { throw TransferError("resposta inesperada") }
    }

    // A connection that cannot join is tolerated: the others take its blocks.
    private func joinAndWork(host: String, port: UInt16, session: Data, plan: Plan) {
        let channel: SecureChannel
        do {
            channel = try open(host: host, port: port)
            var out = ByteWriter(.join)
            out.raw(session)
            try channel.send(out)
            try expectAccept(channel)
        } catch {
            return
        }
        do { try work(channel, plan: plan) } catch { fail(error) }
    }

    private func work(_ channel: SecureChannel, plan: Plan) throws {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Wire.maxPlain, alignment: 16)
        defer { buffer.deallocate() }
        var reader = FileReader()
        defer { reader.close() }
        while true {
            let block = nextBlock.wrappingAdd(1, ordering: .relaxed).oldValue
            guard block < plan.blocks else { return }
            if lock.withLock({ cancelled || failure != nil }) { return }
            var position = Int64(block) * Int64(Wire.blockSize)
            let end = min(plan.total, position + Int64(Wire.blockSize))
            var file = plan.fileIndex(at: position)
            while position < end {
                var used = 0
                buffer.storeBytes(of: MessageType.data.rawValue, as: UInt8.self)
                used = 1
                var payload: Int64 = 0
                while position < end, Wire.maxPlain - used > Wire.segmentHeader {
                    while plan.start[file] + plan.items[file].size <= position { file += 1 }
                    let offset = position - plan.start[file]
                    let count = Int(min(min(end - position, plan.items[file].size - offset), Int64(Wire.maxPlain - used - Wire.segmentHeader)))
                    buffer.storeBE(UInt32(file), at: used)
                    buffer.storeBE(UInt64(offset), at: used + 4)
                    buffer.storeBE(UInt32(count), at: used + 12)
                    used += Wire.segmentHeader
                    try reader.read(plan.items[file], index: file, into: buffer + used, count: count, offset: offset)
                    used += count
                    position += Int64(count)
                    payload += Int64(count)
                }
                try channel.send(UnsafeRawBufferPointer(start: buffer, count: used))
                sentBytes.wrappingAdd(payload, ordering: .relaxed)
            }
        }
    }

    private func fail(_ error: Error) {
        let open = lock.withLock { () -> [SecureChannel] in
            guard failure == nil else { return [] }
            failure = error
            return channels
        }
        open.forEach { $0.abort() }
    }

    private func throwIfFailed() throws {
        let (wasCancelled, error) = lock.withLock { (cancelled, failure) }
        if wasCancelled { throw TransferError("cancelado") }
        if let error { throw error }
    }

    // The concatenated byte stream: item i covers [start[i], start[i] + size).
    private struct Plan {
        let items: [OutgoingItem]
        let start: [Int64]
        let total: Int64
        let blocks: Int

        init(_ items: [OutgoingItem]) {
            self.items = items
            var offsets: [Int64] = []
            var offset: Int64 = 0
            for item in items {
                offsets.append(offset)
                offset += item.size
            }
            start = offsets
            total = offset
            blocks = Int((offset + Int64(Wire.blockSize) - 1) / Int64(Wire.blockSize))
        }

        func fileIndex(at position: Int64) -> Int {
            var low = 0
            var high = start.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if start[mid] <= position { low = mid } else { high = mid - 1 }
            }
            return low
        }
    }

    // Keeps the current file open while a connection walks its block.
    private struct FileReader {
        private var current = -1
        private var fd: Int32 = -1

        mutating func read(_ item: OutgoingItem, index: Int, into pointer: UnsafeMutableRawPointer, count: Int, offset: Int64) throws {
            if index != current {
                close()
                fd = Darwin.open(item.path, O_RDONLY)
                guard fd >= 0 else { throw TransferError("não foi possível ler \(item.relativePath)") }
                current = index
            }
            var done = 0
            while done < count {
                let n = pread(fd, pointer + done, count - done, off_t(offset) + off_t(done))
                if n > 0 { done += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw TransferError("o arquivo mudou durante o envio: \(item.relativePath)")
            }
        }

        mutating func close() {
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
            current = -1
        }
    }
}
