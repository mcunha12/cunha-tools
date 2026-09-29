import Darwin
import Foundation

enum RelativePath {
    // Same rules as the Java core: no absolute paths, no "..", control characters and ':' become '_'.
    static func clean(_ raw: String) throws -> String {
        var parts: [String] = []
        for part in raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { throw TransferError("caminho inválido: \(raw)") }
            parts.append(String(part.map { $0.asciiValue.map { $0 < 0x20 } == true || $0 == ":" ? "_" : $0 }))
        }
        guard !parts.isEmpty else { throw TransferError("caminho vazio") }
        return parts.joined(separator: "/")
    }

    static func topLevel(_ path: String) -> String {
        path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
    }

    // Two manifest items with the same path would share a temp file; the later one gets " (2)", " (3)"...
    static func unique(_ path: String, taken: inout Set<String>, isDirectory: Bool) -> String {
        if taken.insert(path).inserted { return path }
        let slash = path.lastIndex(of: "/")
        let parent = slash.map { String(path[...$0]) } ?? ""
        let name = slash.map { String(path[path.index(after: $0)...]) } ?? path
        var n = 2
        while true {
            let candidate = parent + numbered(name, n, isDirectory: isDirectory)
            if taken.insert(candidate).inserted { return candidate }
            n += 1
        }
    }

    // "foto.jpg" -> "foto (2).jpg"; folders and names without an extension get the suffix at the end.
    static func numbered(_ name: String, _ n: Int, isDirectory: Bool) -> String {
        let ext = (name as NSString).pathExtension
        guard !isDirectory, !ext.isEmpty, name.count > ext.count + 1 else { return "\(name) (\(n))" }
        return "\((name as NSString).deletingPathExtension) (\(n)).\(ext)"
    }
}

// Receives into a folder: temp file per item, pwrite by position, rename on completion.
final class FolderSink: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var names: [String: [String: String]] = [:]

    init(root: URL) {
        self.root = root
    }

    func usableSpace() -> Int64 {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? -1
    }

    func create(session: String, entry: IncomingEntry) throws -> FileTarget {
        let destination = self.destination(session: session, path: entry.path, isDirectory: false)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temp = parent.appendingPathComponent(".\(destination.lastPathComponent).pfs-\(session.prefix(8))")
        return try FileTarget(temp: temp, destination: destination, size: entry.size, modifiedMillis: entry.modifiedMillis)
    }

    func makeDirectory(session: String, entry: IncomingEntry) throws {
        let folder = destination(session: session, path: entry.path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    // Top-level items of this session, as saved on disk.
    func topLevelURLs(session: String) -> [URL] {
        lock.withLock { (names[session] ?? [:]).values.sorted().map { root.appendingPathComponent($0) } }
    }

    func forget(session: String) {
        _ = lock.withLock { names.removeValue(forKey: session) }
    }

    // Existing top-level names get " (2)", " (3)"...; the mapping holds for the whole session.
    private func destination(session: String, path: String, isDirectory: Bool) -> URL {
        let top = RelativePath.topLevel(path)
        let mapped = lock.withLock { () -> String in
            var map = names[session] ?? [:]
            if let existing = map[top] { return existing }
            let folder = isDirectory || path.count > top.count
            var candidate = top
            var n = 2
            while FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) || map.values.contains(candidate) {
                candidate = RelativePath.numbered(top, n, isDirectory: folder)
                n += 1
            }
            map[top] = candidate
            names[session] = map
            return candidate
        }
        return root.appendingPathComponent(mapped + path.dropFirst(top.count))
    }
}

final class FileTarget: @unchecked Sendable {
    private let fd: Int32
    private let temp: URL
    private let destination: URL
    private let modifiedMillis: Int64
    private let lock = NSLock()
    private var finished = false

    init(temp: URL, destination: URL, size: Int64, modifiedMillis: Int64) throws {
        fd = Darwin.open(temp.path, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw TransferError("não foi possível criar \(destination.lastPathComponent)") }
        self.temp = temp
        self.destination = destination
        self.modifiedMillis = modifiedMillis
        if size > 0 {
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE, fst_offset: 0, fst_length: off_t(size), fst_bytesalloc: 0)
            _ = fcntl(fd, F_PREALLOCATE, &store)
            guard ftruncate(fd, off_t(size)) == 0 else {
                Darwin.close(fd)
                unlink(temp.path)
                throw TransferError("sem espaço para \(destination.lastPathComponent)")
            }
        }
    }

    // Holds the lock across pwrite so abort() never closes the descriptor under a write in flight.
    func write(_ pointer: UnsafeRawPointer, count: Int, offset: Int64) throws {
        try lock.withLock {
            guard !finished else { throw TransferError("transferência interrompida") }
            var done = 0
            while done < count {
                let n = pwrite(fd, pointer + done, count - done, off_t(offset) + off_t(done))
                if n > 0 { done += n; continue }
                if n < 0 && errno == EINTR { continue }
                throw TransferError("falha ao gravar \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
    }

    func commit() throws {
        try lock.withLock {
            guard !finished else { return }
            finished = true
            if modifiedMillis > 0 {
                let seconds = Double(modifiedMillis) / 1000
                var times = [timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1e6)), timeval(tv_sec: Int(seconds), tv_usec: 0)]
                times[1] = times[0]
                _ = futimes(fd, &times)
            }
            Darwin.close(fd)
            var target = destination
            var n = 2
            while renamex_np(temp.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else { throw TransferError("não foi possível salvar \(destination.lastPathComponent)") }
                target = destination.deletingLastPathComponent().appendingPathComponent(RelativePath.numbered(destination.lastPathComponent, n, isDirectory: false))
                n += 1
            }
        }
    }

    func abort() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            Darwin.close(fd)
            unlink(temp.path)
        }
    }
}
