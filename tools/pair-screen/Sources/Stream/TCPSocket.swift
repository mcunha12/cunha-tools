import Darwin
import Foundation

struct SocketError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Blocking TCP socket to 127.0.0.1; each stream reads on its own thread, so blocking I/O is the cheapest option.
final class TCPSocket: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var isShutdown = false

    private init(fd: Int32) { self.fd = fd }

    static func connectLocal(port: UInt16) throws -> TCPSocket {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(message: "socket() falhou: \(errno)") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw SocketError(message: "connect() falhou na porta \(port): \(errno)")
        }
        return TCPSocket(fd: fd)
    }

    func setNoDelay() {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    // Reads exactly count bytes into pointer; false on EOF or error.
    func readFully(into pointer: UnsafeMutableRawPointer, count: Int) -> Bool {
        var done = 0
        while done < count {
            let r = Darwin.read(fd, pointer + done, count - done)
            if r > 0 {
                done += r
            } else if r < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    func readFully(count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        let ok = buffer.withUnsafeMutableBytes { readFully(into: $0.baseAddress!, count: count) }
        return ok ? buffer : nil
    }

    // Returns the number of bytes read, 0 on EOF, -1 on error.
    func readSome(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        while true {
            let r = Darwin.read(fd, buffer.baseAddress!, buffer.count)
            if r < 0, errno == EINTR { continue }
            return r
        }
    }

    func writeAll(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { raw in
            var done = 0
            while done < raw.count {
                let w = Darwin.write(fd, raw.baseAddress! + done, raw.count - done)
                if w > 0 {
                    done += w
                } else if w < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    // Unblocks pending reads on other threads; the descriptor is released in deinit, after every reader let go.
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutdown else { return }
        isShutdown = true
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    deinit { Darwin.close(fd) }
}
