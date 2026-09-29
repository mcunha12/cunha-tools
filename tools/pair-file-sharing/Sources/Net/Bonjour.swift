import dnssd
import Foundation

private let bonjourQueue = DispatchQueue(label: "com.marcelocunha.pairfilesharing.bonjour")

private func txtRecord(_ values: [String: String]) -> [UInt8] {
    var bytes: [UInt8] = []
    for (key, value) in values.sorted(by: { $0.key < $1.key }) {
        let entry = Array("\(key)=\(value)".utf8.prefix(255))
        bytes.append(UInt8(entry.count))
        bytes.append(contentsOf: entry)
    }
    return bytes
}

private func txtValue(_ key: String, length: UInt16, record: UnsafePointer<UInt8>?) -> String? {
    guard let record else { return nil }
    var size: UInt8 = 0
    guard let pointer = TXTRecordGetValuePtr(length, record, key, &size) else { return nil }
    return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(size)), as: UTF8.self)
}

// Publishes _cunhapfs._tcp with TXT role and id; the daemon keeps it alive while the reference is open.
final class BonjourAdvertiser: @unchecked Sendable {
    private var reference: DNSServiceRef?

    func start(name: String, port: UInt16, txt: [String: String]) {
        bonjourQueue.async { [self] in
            guard reference == nil else { return }
            let record = txtRecord(txt)
            var ref: DNSServiceRef?
            let callback: DNSServiceRegisterReply = { _, _, _, _, _, _, _ in }
            let status = DNSServiceRegister(&ref, 0, 0, name, Wire.serviceType, nil, nil, port.bigEndian, UInt16(record.count), record, callback, nil)
            guard status == kDNSServiceErr_NoError, let ref else { return }
            DNSServiceSetDispatchQueue(ref, bonjourQueue)
            reference = ref
        }
    }

    func stop() {
        bonjourQueue.async { [self] in
            if let reference { DNSServiceRefDeallocate(reference) }
            reference = nil
        }
    }
}

struct BonjourPeer: Sendable {
    let id: String
    let role: String
    let host: String
    let port: UInt16
    let seen: Date
}

// Browses _cunhapfs._tcp and resolves each instance to IPv4 + port + TXT id.
final class BonjourBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [String: BonjourPeer] = [:]
    private var instanceIDs: [String: String] = [:]
    private var browseReference: DNSServiceRef?
    private var jobs: [ObjectIdentifier: ResolveJob] = [:]

    func peer(id: String) -> BonjourPeer? { lock.withLock { peers[id] } }

    func start() {
        bonjourQueue.async { [self] in
            guard browseReference == nil else { return }
            var ref: DNSServiceRef?
            let context = Unmanaged.passUnretained(self).toOpaque()
            let callback: DNSServiceBrowseReply = { _, flags, interface, error, name, type, domain, context in
                guard error == kDNSServiceErr_NoError, let context, let name, let type, let domain else { return }
                let browser = Unmanaged<BonjourBrowser>.fromOpaque(context).takeUnretainedValue()
                let instance = String(cString: name)
                if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
                    browser.resolve(instance: instance, type: String(cString: type), domain: String(cString: domain), interface: interface)
                } else {
                    browser.forget(instance: instance)
                }
            }
            guard DNSServiceBrowse(&ref, 0, 0, Wire.serviceType, nil, callback, context) == kDNSServiceErr_NoError, let ref else { return }
            DNSServiceSetDispatchQueue(ref, bonjourQueue)
            browseReference = ref
        }
    }

    // Asks for a fresh resolution of every known instance; used right before a send.
    func refresh() {
        bonjourQueue.async { [self] in
            if let browseReference { DNSServiceRefDeallocate(browseReference) }
            browseReference = nil
            start()
        }
    }

    private func forget(instance: String) {
        lock.withLock {
            if let id = instanceIDs.removeValue(forKey: instance) { peers.removeValue(forKey: id) }
        }
    }

    private func resolve(instance: String, type: String, domain: String, interface: UInt32) {
        let job = ResolveJob(browser: self, instance: instance, interface: interface)
        jobs[ObjectIdentifier(job)] = job
        let callback: DNSServiceResolveReply = { _, _, _, error, _, host, port, length, record, context in
            guard let context else { return }
            let job = Unmanaged<ResolveJob>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, let host else { return job.finish() }
            job.resolved(host: String(cString: host), port: UInt16(bigEndian: port), id: txtValue("id", length: length, record: record), role: txtValue("role", length: length, record: record))
        }
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(job).toOpaque()
        guard DNSServiceResolve(&ref, 0, interface, instance, type, domain, callback, context) == kDNSServiceErr_NoError, let ref else {
            jobs.removeValue(forKey: ObjectIdentifier(job))
            return
        }
        DNSServiceSetDispatchQueue(ref, bonjourQueue)
        job.references.append(ref)
        bonjourQueue.asyncAfter(deadline: .now() + 8) { job.finish() }
    }

    fileprivate func store(_ peer: BonjourPeer, instance: String) {
        lock.withLock {
            peers[peer.id] = peer
            instanceIDs[instance] = peer.id
        }
    }

    fileprivate func finished(_ job: ResolveJob) {
        jobs.removeValue(forKey: ObjectIdentifier(job))
    }
}

// Resolve, then IPv4 lookup; lives on bonjourQueue until it stores a peer or times out.
private final class ResolveJob {
    unowned let browser: BonjourBrowser
    let instance: String
    let interface: UInt32
    var references: [DNSServiceRef] = []
    private var port: UInt16 = 0
    private var id: String?
    private var role: String?
    private var done = false

    init(browser: BonjourBrowser, instance: String, interface: UInt32) {
        self.browser = browser
        self.instance = instance
        self.interface = interface
    }

    func resolved(host: String, port: UInt16, id: String?, role: String?) {
        guard !done else { return }
        guard let id else { return finish() }
        guard references.count == 1 else { return }
        self.port = port
        self.id = id
        self.role = role
        let callback: DNSServiceGetAddrInfoReply = { _, _, _, error, _, address, _, context in
            guard let context else { return }
            let job = Unmanaged<ResolveJob>.fromOpaque(context).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError, let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                var ip = pointer.pointee.sin_addr
                _ = inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count))
            }
            job.addressed(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        var ref: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard DNSServiceGetAddrInfo(&ref, 0, interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host, callback, context) == kDNSServiceErr_NoError, let ref else { return finish() }
        DNSServiceSetDispatchQueue(ref, bonjourQueue)
        references.append(ref)
    }

    func addressed(_ ip: String) {
        guard !done, let id, !ip.hasPrefix("169.254.") else { return }
        browser.store(BonjourPeer(id: id, role: role ?? "", host: ip, port: port, seen: Date()), instance: instance)
        bonjourQueue.async { self.finish() }
    }

    func finish() {
        guard !done else { return }
        done = true
        references.forEach { DNSServiceRefDeallocate($0) }
        references.removeAll()
        browser.finished(self)
    }
}
