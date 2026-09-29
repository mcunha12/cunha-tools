import Foundation
import Network

// Browses one adb Bonjour type with NWBrowser; NetService resolves host:port without opening a connection to the phone.
@MainActor
final class BonjourFinder {
    private let type: String
    private let onFound: @MainActor (_ name: String, _ address: String) -> Void
    private let onFailure: @MainActor (String) -> Void
    private var browser: NWBrowser?
    private var resolvers: [String: ServiceResolver] = [:]

    init(type: String, onFailure: @escaping @MainActor (String) -> Void, onFound: @escaping @MainActor (_ name: String, _ address: String) -> Void) {
        self.type = type
        self.onFailure = onFailure
        self.onFound = onFound
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: NWParameters())
        browser.stateUpdateHandler = { [weak self] state in
            let error: NWError? = switch state {
            case let .failed(error), let .waiting(error): error
            default: nil
            }
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.onFailure("A busca na rede local falhou (\(error.localizedDescription)). Libere o Cunha Tools em Ajustes do Sistema → Privacidade e Segurança → Rede local.")
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            }
            MainActor.assumeIsolated { names.forEach { self?.resolve($0) } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
    }

    private func resolve(_ name: String) {
        guard resolvers[name] == nil else { return }
        let resolver = ServiceResolver(name: name, type: type) { [weak self] address in
            MainActor.assumeIsolated {
                self?.resolvers[name] = nil
                if let address { self?.onFound(name, address) }
            }
        }
        resolvers[name] = resolver
        resolver.start()
    }
}

private final class ServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private let completion: (String?) -> Void
    private var finished = false

    init(name: String, type: String, completion: @escaping (String?) -> Void) {
        service = NetService(domain: "local.", type: type + ".", name: name)
        self.completion = completion
    }

    func start() {
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func cancel() {
        finished = true
        service.stop()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let address = Self.address(sender) else { return }
        finish(address)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { finish(nil) }

    private func finish(_ address: String?) {
        guard !finished else { return }
        finished = true
        service.stop()
        completion(address)
    }

    // IPv4 first, since adb and the phone's screen both use it; the .local host name is the fallback.
    private static func address(_ service: NetService) -> String? {
        guard service.port > 0 else { return nil }
        for data in service.addresses ?? [] {
            let ipv4 = data.withUnsafeBytes { raw -> String? in
                guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var socket = raw.load(as: sockaddr_in.self)
                guard socket.sin_family == sa_family_t(AF_INET) else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &socket.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                return String(cString: buffer)
            }
            if let ipv4 { return "\(ipv4):\(service.port)" }
        }
        guard let host = service.hostName else { return nil }
        return "\(host.hasSuffix(".") ? String(host.dropLast()) : host):\(service.port)"
    }
}
