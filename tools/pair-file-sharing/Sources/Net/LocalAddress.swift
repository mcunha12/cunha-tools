import Darwin
import Foundation

enum LocalAddress {
    // IPv4 of the active Wi-Fi or Ethernet interface; en0 wins when several are up.
    static func primaryIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, ip: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = list
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var ip = pointer.pointee.sin_addr
                _ = inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count))
            }
            let ip = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !ip.hasPrefix("169.254.") { found.append((name, ip)) }
        }
        return (found.first { $0.name == "en0" } ?? found.first)?.ip
    }
}
