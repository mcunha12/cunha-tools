import Foundation
import Synchronization

struct IncomingEntry: Sendable {
    let path: String
    let size: Int64
    let modifiedMillis: Int64
    let isDirectory: Bool
}

// One incoming transfer: the manifest, the files being written and the connections feeding them.
final class ReceiveSession: @unchecked Sendable {
    let id: String
    let peer: PeerInfo
    let entries: [IncomingEntry]
    let total: Int64
    let startedAt = Date()
    private let sink: FolderSink
    private let onEnd: (ReceiveSession, String?) -> Void
    private let receivedBytes = Atomic<Int64>(0)
    private let lastProgress = Atomic<UInt64>(DispatchTime.now().uptimeNanoseconds)
    private let lock = NSLock()
    private var targets: [FileTarget?]
    private var committed: [Bool]
    private var remaining: [Int64]
    private var channels: [SecureChannel] = []
    private var failure: String?
    private var ended = false

    init(id: String, peer: PeerInfo, entries: [IncomingEntry], total: Int64, sink: FolderSink, onEnd: @escaping (ReceiveSession, String?) -> Void) {
        self.id = id
        self.peer = peer
        self.entries = entries
        self.total = total
        self.sink = sink
        self.onEnd = onEnd
        targets = Array(repeating: nil, count: entries.count)
        committed = Array(repeating: false, count: entries.count)
        remaining = entries.map(\.size)
    }

    var received: Int64 { receivedBytes.load(ordering: .relaxed) }
    var isEnded: Bool { lock.withLock { ended } }
    var savedURLs: [URL] { sink.topLevelURLs(session: id) }

    func cancel() { fail("cancelado") }

    func attach(_ channel: SecureChannel) throws {
        try lock.withLock {
            channels.append(channel)
            if let failure { throw TransferError(failure) }
        }
    }

    // DATA payload after the type byte: repeated [u32 file][u64 offset][u32 length][bytes].
    func write(_ frame: Data) throws {
        try frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let end = raw.count
            var at = 1
            while at < end {
                guard end - at >= Wire.segmentHeader else { throw TransferError("segmento truncado") }
                let file = Int(base.loadBE32(at: at))
                let offset = Int64(bitPattern: base.loadBE64(at: at + 4))
                let length = Int(base.loadBE32(at: at + 12))
                at += Wire.segmentHeader
                guard file < entries.count, length <= end - at, offset >= 0, offset + Int64(length) <= entries[file].size else {
                    throw TransferError("segmento fora do manifesto")
                }
                try target(file).write(base + at, count: length, offset: offset)
                at += length
                let left = try lock.withLock { () -> Int64 in
                    remaining[file] -= Int64(length)
                    guard remaining[file] >= 0 else { throw TransferError("dados duplicados") }
                    return remaining[file]
                }
                if left == 0 { try commit(file) }
                // Counted after the commit, so received == total means every file is already in place.
                receivedBytes.wrappingAdd(Int64(length), ordering: .relaxed)
                lastProgress.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
            }
        }
    }

    private func target(_ file: Int) throws -> FileTarget {
        try lock.withLock {
            if let failure { throw TransferError(failure) }
            if let target = targets[file] { return target }
            let target = try sink.create(session: id, entry: entries[file])
            targets[file] = target
            return target
        }
    }

    private func commit(_ file: Int) throws {
        try target(file).commit()
        lock.withLock { committed[file] = true }
    }

    // Waits for the other connections to drain, then writes empty files and folders.
    func complete() throws {
        while received < total {
            if let failure = lock.withLock({ failure }) { throw TransferError(failure) }
            let idle = DispatchTime.now().uptimeNanoseconds - lastProgress.load(ordering: .relaxed)
            if idle > UInt64(Wire.ioTimeout * 1e9) { throw TransferError("dados incompletos") }
            usleep(2000)
        }
        for (index, entry) in entries.enumerated() {
            if entry.isDirectory {
                try sink.makeDirectory(session: id, entry: entry)
            } else if entry.size == 0 {
                try commit(index)
            }
        }
        let first = lock.withLock { () -> Bool in
            defer { ended = true }
            return !ended
        }
        if first { onEnd(self, nil) }
    }

    func fail(_ reason: String) {
        let state = lock.withLock { () -> ([SecureChannel], [FileTarget])? in
            guard !ended else { return nil }
            ended = true
            failure = reason
            return (channels, targets.indices.compactMap { committed[$0] ? nil : targets[$0] })
        }
        guard let (open, pending) = state else { return }
        open.forEach { $0.abort() }
        pending.forEach { $0.abort() }
        onEnd(self, reason)
    }
}
