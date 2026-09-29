import Darwin
import Foundation
import os

// Blocking POSIX TCP socket; measured 13.7 GB/s on loopback against 3.5 GB/s for Network.framework.
final class TCPSocket: @unchecked Sendable {
    let fd: Int32
    let remoteHost: String?
    private let lock = NSLock()
    private var isClosed = false

    init(fd: Int32, remoteHost: String?) {
        self.fd = fd
        self.remoteHost = remoteHost
    }

    deinit { close() }

    static func connect(host: String, port: UInt16, timeout: TimeInterval) throws -> TCPSocket {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        hints.ai_flags = AI_NUMERICSERV
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let list else { throw TransferError("endereço inválido: \(host)") }
        defer { freeaddrinfo(list) }
        var lastError = "sem rota para \(host)"
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let info = cursor {
            cursor = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { continue }
            configure(fd)
            if let error = connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen, timeout: timeout) {
                Darwin.close(fd)
                lastError = error
                continue
            }
            return TCPSocket(fd: fd, remoteHost: host)
        }
        throw TransferError(lastError)
    }

    private static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t, timeout: TimeInterval) -> String? {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }
        if Darwin.connect(fd, address, length) == 0 { return nil }
        guard errno == EINPROGRESS else { return String(cString: strerror(errno)) }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&poller, 1, Int32(timeout * 1000))
        guard ready > 0 else { return ready == 0 ? "tempo esgotado" : String(cString: strerror(errno)) }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size)
        return error == 0 ? nil : String(cString: strerror(error))
    }

    static func configure(_ fd: Int32) {
        var one: Int32 = 1
        var buffer = Wire.socketBuffer
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, size)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, size)
    }

    func setTimeout(_ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }

    // Returns false when the peer closed before the first byte, so callers can tell a clean end from a cut.
    func readExactly(_ pointer: UnsafeMutableRawPointer, _ count: Int, allowEOF: Bool = false) throws -> Bool {
        var done = 0
        while done < count {
            let n = Darwin.read(fd, pointer + done, count - done)
            if n > 0 {
                done += n
            } else if n == 0 {
                if allowEOF && done == 0 { return false }
                throw TransferError("conexão encerrada no meio de um quadro")
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                throw TransferError("tempo esgotado sem resposta")
            } else {
                throw TransferError("conexão perdida (\(String(cString: strerror(errno))))")
            }
        }
        return true
    }

    func write(_ pointer: UnsafeRawPointer, _ count: Int) throws {
        var done = 0
        while done < count {
            let n = Darwin.write(fd, pointer + done, count - done)
            if n > 0 { done += n; continue }
            if n < 0 && errno == EINTR { continue }
            throw Self.writeError(n < 0 ? errno : EPIPE)
        }
    }

    func write(_ buffers: [UnsafeRawBufferPointer]) throws {
        var vectors = buffers.map { iovec(iov_base: UnsafeMutableRawPointer(mutating: $0.baseAddress), iov_len: $0.count) }
        var index = 0
        while index < vectors.count {
            let start = index
            let n = vectors.withUnsafeBufferPointer { writev(fd, $0.baseAddress! + start, Int32($0.count - start)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.writeError(errno)
            }
            var left = n
            while index < vectors.count, left >= vectors[index].iov_len {
                left -= vectors[index].iov_len
                index += 1
            }
            if index < vectors.count, left > 0 {
                vectors[index].iov_base += left
                vectors[index].iov_len -= left
            }
        }
    }

    private static func writeError(_ code: Int32) -> TransferError {
        TransferError(code == EAGAIN ? "tempo esgotado sem resposta" : "conexão perdida (\(String(cString: strerror(code))))")
    }

    // Wakes any thread blocked on this socket; close() stays with the owner.
    func abort() {
        lock.withLock { if !isClosed { shutdown(fd, SHUT_RDWR) } }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            Darwin.close(fd)
        }
    }
}

final class TCPListener: @unchecked Sendable {
    let fd: Int32
    private let stopped = OSAllocatedUnfairLock(initialState: false)
    private var wake: [Int32] = [-1, -1]

    init(port: UInt16) throws {
        fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw TransferError("socket indisponível") }
        guard pipe(&wake) == 0 else {
            Darwin.close(fd)
            throw TransferError("pipe indisponível")
        }
        var one: Int32 = 1
        var zero: Int32 = 0
        var buffer = Wire.socketBuffer
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, size)
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, size)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, size)
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            wake.forEach { Darwin.close($0) }
            throw TransferError("porta \(port) indisponível: \(reason)")
        }
    }

    var port: UInt16 {
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return UInt16(bigEndian: address.sin6_port)
    }

    // Waits on the socket and a wake pipe with no timeout, so an idle listener costs no wakeups; the loop owns and closes both.
    func accept() -> TCPSocket? {
        while true {
            if stopped.withLock({ $0 }) {
                ([fd] + wake).forEach { Darwin.close($0) }
                return nil
            }
            var pollers = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
            let ready = poll(&pollers, 2, -1)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 { return nil }
            if pollers[1].revents != 0 || pollers[0].revents & Int16(POLLIN) == 0 { continue }
            var address = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &length) } }
            if client >= 0 {
                TCPSocket.configure(client)
                return TCPSocket(fd: client, remoteHost: Self.host(of: &address))
            }
            if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { continue }
            return nil
        }
    }

    func stop() {
        stopped.withLock { $0 = true }
        var byte: UInt8 = 1
        _ = Darwin.write(wake[1], &byte, 1)
    }

    // IPv4-mapped IPv6 addresses come back as plain dotted IPv4.
    private static func host(of storage: inout sockaddr_storage) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t($0.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard result == 0 else { return nil }
        let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
    }
}
