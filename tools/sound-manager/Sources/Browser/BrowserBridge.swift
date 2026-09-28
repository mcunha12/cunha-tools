import Foundation
import Network

struct BrowserTab: Identifiable, Equatable, Decodable {
    let id: Int
    let windowId: Int
    let title: String
    let url: String
    let favIconUrl: String?
    let audible: Bool
    var muted: Bool
    let volume: Double
    let playing: Bool?
    let volumeSupported: Bool

    var hasSound: Bool {
        audible || ((muted || volume < 1) && playing != false)
    }
}

struct BrowserSession: Identifiable, Equatable {
    let id: UUID
    var brands: [String] = []
    var tabs: [BrowserTab] = []
}

@MainActor
final class BrowserBridge: ObservableObject {
    static let port = ProcessInfo.processInfo.environment["SOUNDMANAGER_PORT"].flatMap { NWEndpoint.Port($0) } ?? 47821

    @Published private(set) var sessions: [UUID: BrowserSession] = [:]
    @Published private(set) var listenerError: String?

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    func start() {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setClientRequestHandler(.main) { _, headers in
            let origin = headers.first { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }?.value ?? ""
            let allowed = ["chrome-extension://", "moz-extension://"].contains { origin.hasPrefix($0) }
            return NWProtocolWebSocket.Response(status: allowed ? .accept : .reject, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.listenerError = nil
                    case .failed(let error): self?.retry(after: error)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            retry(after: error)
        }
    }

    private func retry(after error: Error) {
        NSLog("SoundManager: servidor da extensão falhou: \(error.localizedDescription)")
        listenerError = error.localizedDescription
        listener?.cancel()
        listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    func setMuted(_ muted: Bool, tab: BrowserTab, session: UUID) {
        if let index = sessions[session]?.tabs.firstIndex(where: { $0.id == tab.id }) {
            sessions[session]?.tabs[index].muted = muted
        }
        send(["type": "setMuted", "tabId": tab.id, "muted": muted], to: session)
    }

    func setVolume(_ volume: Double, tab: BrowserTab, session: UUID) {
        send(["type": "setVolume", "tabId": tab.id, "volume": volume], to: session)
    }

    func tabsWithSound(in sessions: [BrowserSession]) -> [BrowserTab] {
        sessions.flatMap(\.tabs).filter(\.hasSound)
    }

    func sessions(matchingAppNamed name: String, bundleID: String?) -> [BrowserSession] {
        sessions.values
            .filter { BrowserCatalog.session($0, belongsTo: name, bundleID: bundleID) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.sessions[id] = BrowserSession(id: id)
                case .failed, .cancelled: self?.drop(id)
                default: break
                }
            }
        }
        receive(on: connection, id: id)
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.handle(data, from: id) }
                if error != nil {
                    connection.cancel()
                    return
                }
                self.receive(on: connection, id: id)
            }
        }
    }

    private func handle(_ data: Data, from id: UUID) {
        guard let message = try? JSONDecoder().decode(IncomingMessage.self, from: data) else { return }
        var session = sessions[id] ?? BrowserSession(id: id)
        if let brands = message.brands { session.brands = brands }
        if let tabs = message.tabs { session.tabs = tabs }
        if sessions[id] != session { sessions[id] = session }
    }

    private func drop(_ id: UUID) {
        connections[id]?.cancel()
        connections[id] = nil
        sessions[id] = nil
    }

    private func send(_ payload: [String: Any], to id: UUID) {
        guard let connection = connections[id], let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "command", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

private struct IncomingMessage: Decodable {
    let type: String
    let brands: [String]?
    let tabs: [BrowserTab]?
}
