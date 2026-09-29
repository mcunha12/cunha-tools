import AppKit
import CunhaKit
import Foundation

// Keys the listener accepts: the saved pairing and, while the pairing window is open, the pending one.
final class KeyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Data?
    private var pending: Data?

    func set(current: Data?) { lock.withLock { self.current = current } }
    func set(pending: Data?) { lock.withLock { self.pending = pending } }

    func lookup(_ keyID: Data) -> Data? {
        lock.withLock { [current, pending].compactMap { $0 }.first { SecureChannel.keyID(for: $0) == keyID } }
    }

    func isPending(_ keyID: Data) -> Bool {
        lock.withLock { pending.map { SecureChannel.keyID(for: $0) == keyID } ?? false }
    }
}

struct Transfer: Identifiable, Equatable {
    enum Direction { case send, receive }

    let id: String
    let direction: Direction
    var title: String
    var total: Int64 = 0
    var done: Int64 = 0
    var bytesPerSecond: Double = 0

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    var secondsLeft: Double? { bytesPerSecond > 0 && total > done ? Double(total - done) / bytesPerSecond : nil }
}

struct Outcome: Equatable {
    let text: String
    let isError: Bool
    var urls: [URL] = []
}

@MainActor
final class TransferCenter: ObservableObject {
    @Published private(set) var pairing: Pairing?
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var listenerError: String?

    // `-receiveFolder <path>` on the command line (or the same default) overrides ~/Downloads/Pair File Sharing.
    let downloads = UserDefaults.standard.string(forKey: "receiveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Pair File Sharing", isDirectory: true)
    let keys = KeyStore()
    var notifier: Notifier?
    var openPairing: () -> Void = {}
    var onPairingConfirmed: ((PeerInfo) -> Void)?

    private let advertiser = BonjourAdvertiser()
    private let browser = BonjourBrowser()
    private var server: TransferServer?
    private var senders: [String: TransferSender] = [:]
    private var sessions: [String: ReceiveSession] = [:]
    private var samples: [String: [(time: Date, bytes: Int64)]] = [:]
    private var ticker: Timer?

    func start() {
        pairing = PairingStore.load()
        keys.set(current: pairing?.keyData)
        publishStatus()
        var events = TransferServer.Events()
        events.peer = { peer in Task { @MainActor [weak self] in self?.peerSeen(peer) } }
        events.started = { session in Task { @MainActor [weak self] in self?.receiveStarted(session) } }
        events.ended = { session, error in Task { @MainActor [weak self] in self?.receiveEnded(session, error: error) } }
        let keys = keys
        let server = TransferServer(port: Wire.macPort, role: Wire.roleMac, id: MacIdentity.id, name: MacIdentity.name, sink: FolderSink(root: downloads), keys: { keys.lookup($0) }, events: events)
        do {
            try server.start()
            self.server = server
        } catch {
            listenerError = error.localizedDescription
        }
        advertiser.start(name: MacIdentity.name, port: Wire.macPort, txt: ["role": "mac", "id": MacIdentity.id])
        browser.start()
    }

    func stop() {
        server?.stop()
        advertiser.stop()
        senders.values.forEach { $0.cancel() }
    }

    // Fixed state for --selftest-render.
    func preview(pairing: Pairing?, transfers: [Transfer], outcome: Outcome?) {
        self.pairing = pairing
        self.transfers = transfers
        lastOutcome = outcome
    }

    // MARK: Pairing

    func setPendingKey(_ key: Data?) {
        keys.set(pending: key)
    }

    func savePairing(_ new: Pairing) {
        do {
            try PairingStore.save(new)
        } catch {
            lastOutcome = Outcome(text: error.localizedDescription, isError: true)
        }
        pairing = new
        keys.set(current: new.keyData)
        publishStatus()
    }

    private func publishStatus() {
        let complete = pairing?.isComplete == true
        ToolStatus.publish(setupComplete: complete, detail: complete ? "Pareado com \(pairing!.displayName)" : "Nenhum celular pareado")
    }

    private func peerSeen(_ peer: PeerInfo) {
        if keys.isPending(peer.keyID) {
            onPairingConfirmed?(peer)
            return
        }
        guard var current = pairing, let key = current.keyData, SecureChannel.keyID(for: key) == peer.keyID else { return }
        current.phoneID = peer.id
        current.phoneName = peer.name
        if let host = peer.host { current.phoneHost = host }
        if peer.port != 0 { current.phonePort = Int(peer.port) }
        if current != pairing { savePairing(current) }
    }

    // MARK: Sending

    func send(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard let pairing, pairing.isComplete, let key = pairing.keyData else {
            lastOutcome = Outcome(text: "Pareie o celular antes de enviar.", isError: true)
            openPairing()
            return
        }
        let id = UUID().uuidString
        let sender = TransferSender(key: key, role: Wire.roleMac, id: pairing.macID, name: MacIdentity.name)
        senders[id] = sender
        let title = urls.count == 1 ? "Enviando \(urls[0].lastPathComponent)" : "Enviando \(urls.count) itens"
        transfers.append(Transfer(id: id, direction: .send, title: title))
        startTicker()
        browser.refresh()
        let known = endpoints(for: pairing)
        let phoneID = pairing.phoneID
        let browser = browser
        Task {
            let outcome = await Self.deliver(urls: urls, sender: sender, known: known, fresh: { phoneID.flatMap { browser.peer(id: $0) }.map { ($0.host, $0.port) } })
            finishSend(id: id, outcome: outcome, phone: pairing.displayName)
        }
    }

    private func endpoints(for pairing: Pairing) -> [(String, UInt16)] {
        var list: [(String, UInt16)] = []
        if let id = pairing.phoneID, let peer = browser.peer(id: id) { list.append((peer.host, peer.port)) }
        if let host = pairing.phoneHost, !list.contains(where: { $0.0 == host }) { list.append((host, UInt16(pairing.phonePort ?? Int(Wire.phonePort)))) }
        return list
    }

    // Tries the known addresses; if none answers and adb sees the phone, wakes the service and tries again.
    private nonisolated static func deliver(urls: [URL], sender: TransferSender, known: [(String, UInt16)], fresh: @escaping @Sendable () -> (String, UInt16)?) async -> Result<SendResult, Error> {
        let items = await blocking { OutgoingItem.collect(urls) }
        guard !items.isEmpty else { return .failure(TransferError("Nada para enviar.")) }
        var tried = Set<String>()
        func attempt(_ candidates: [(String, UInt16)]) async -> Result<SendResult, Error>? {
            for (host, port) in candidates where !tried.contains("\(host):\(port)") {
                tried.insert("\(host):\(port)")
                let result = await blocking { Result { try sender.send(host: host, port: port, items: items) } }
                if case .failure(let error) = result, error is ConnectError, !sender.isCancelled { continue }
                return result
            }
            return nil
        }
        if let result = await attempt(known) { return result }
        try? await Task.sleep(for: .milliseconds(800))
        if let result = await attempt(fresh().map { [$0] } ?? []) { return result }
        if let device = await ADB.preferredDevice(), await ADB.isCompanionInstalled(serial: device.serial) {
            await PhoneADB.wake(serial: device.serial)
            try? await Task.sleep(for: .seconds(1.5))
            let viaADB = await PhoneADB.wifiAddress(serial: device.serial).map { [($0, Wire.phonePort)] } ?? []
            tried.removeAll()
            if let result = await attempt(viaADB + (fresh().map { [$0] } ?? []) + known) { return result }
        }
        if sender.isCancelled { return .failure(TransferError("cancelado")) }
        return .failure(TransferError("Celular não encontrado na rede. Abra o Cunha Tools no celular e confira se ele está no mesmo Wi-Fi."))
    }

    private nonisolated static func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: work()) }.start()
        }
    }

    private func finishSend(id: String, outcome: Result<SendResult, Error>, phone: String) {
        senders.removeValue(forKey: id)
        transfers.removeAll { $0.id == id }
        samples.removeValue(forKey: id)
        switch outcome {
        case .success(let result):
            lastOutcome = Outcome(text: "Enviado para \(phone): \(Format.items(result.files)), \(Format.bytes(result.bytes)) em \(Format.duration(result.seconds)) (\(Format.rate(result.megabytesPerSecond * 1e6)))", isError: false)
        case .failure(let error):
            let text = error.localizedDescription
            lastOutcome = Outcome(text: text == "cancelado" ? "Envio cancelado." : "Envio falhou: \(text)", isError: text != "cancelado")
        }
    }

    // MARK: Receiving

    private func receiveStarted(_ session: ReceiveSession) {
        sessions[session.id] = session
        let title = session.entries.count == 1 ? "Recebendo \(session.entries[0].path)" : "Recebendo \(Format.items(session.entries.count)) de \(session.peer.name)"
        transfers.append(Transfer(id: session.id, direction: .receive, title: title, total: session.total))
        startTicker()
    }

    private func receiveEnded(_ session: ReceiveSession, error: String?) {
        guard sessions.removeValue(forKey: session.id) != nil else { return }
        transfers.removeAll { $0.id == session.id }
        samples.removeValue(forKey: session.id)
        let seconds = Date().timeIntervalSince(session.startedAt)
        if let error {
            lastOutcome = Outcome(text: error == "cancelado" ? "Recebimento cancelado." : "Recebimento falhou: \(error)", isError: error != "cancelado")
            return
        }
        let urls = session.savedURLs
        let summary = "\(Format.items(session.entries.count)), \(Format.bytes(session.total)) em \(Format.duration(seconds)) (\(Format.rate(Double(session.total) / max(seconds, 0.001))))"
        lastOutcome = Outcome(text: "Recebido de \(session.peer.name): \(summary)", isError: false, urls: urls)
        let body = urls.count == 1 ? urls[0].lastPathComponent : Format.items(session.entries.count)
        notifier?.received(title: "Recebido de \(session.peer.name)", body: "\(body) · \(Format.bytes(session.total))", urls: urls)
    }

    // MARK: Progress

    func cancel(_ transfer: Transfer) {
        senders[transfer.id]?.cancel()
        sessions[transfer.id]?.cancel()
    }

    func reveal(_ urls: [URL]) {
        if urls.isEmpty { openDownloads() } else { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func openDownloads() {
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        NSWorkspace.shared.open(downloads)
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // Rate over the last 3 s of samples, so the number follows the link without jumping on every frame.
    private func tick() {
        guard !transfers.isEmpty else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        let now = Date()
        for index in transfers.indices {
            let id = transfers[index].id
            let (done, total): (Int64, Int64)
            if let sender = senders[id] {
                (done, total) = (sender.sent, sender.total)
            } else if let session = sessions[id] {
                (done, total) = (session.received, session.total)
            } else {
                continue
            }
            var history = (samples[id] ?? []) + [(now, done)]
            history.removeAll { now.timeIntervalSince($0.time) > 3 }
            samples[id] = history
            if let first = history.first, now.timeIntervalSince(first.time) > 0.4 {
                transfers[index].bytesPerSecond = Double(done - first.bytes) / now.timeIntervalSince(first.time)
            }
            transfers[index].done = done
            transfers[index].total = total
        }
    }
}
