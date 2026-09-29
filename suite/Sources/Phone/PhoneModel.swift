import AppKit
import CunhaKit

@MainActor
final class PhoneModel: ObservableObject {
    enum Pairing: Equatable {
        case idle
        case waitingForScan(PairingSession)
        case pairing
        case connecting
    }

    static let pairingType = "_adb-tls-pairing._tcp"
    static let connectType = "_adb-tls-connect._tcp"

    @Published private(set) var adbURL = ADB.executableURL
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadError: String?
    @Published private(set) var devices: [ADBDevice] = []
    @Published private(set) var companionVersion: String?
    @Published private(set) var pairing = Pairing.idle
    @Published private(set) var pairingMessage: String?
    @Published private(set) var phoneNotSeen = false
    @Published private(set) var companionBusy = false
    @Published private(set) var companionError: String?
    @Published var manualPairAddress = ""
    @Published var manualCode = ""
    @Published var manualConnectAddress = ""

    let apkURL = Companion.apkURL
    private lazy var tracker = DeviceTracker { [weak self] in self?.devicesChanged($0) }
    private var pairFinder: BonjourFinder?
    private var connectFinder: BonjourFinder?
    private var scanHint: Task<Void, Never>?
    private var connectHint: Task<Void, Never>?
    private var activation: NSObjectProtocol?

    // USB first, then Wi-Fi, same order as ADB.preferredDevice.
    var device: ADBDevice? {
        let online = devices.filter(\.isOnline)
        return online.first { !$0.isWireless } ?? online.first
    }

    var waitingDevice: ADBDevice? { device == nil ? devices.first { !$0.isOnline } : nil }
    var isReady: Bool { device != nil && companionVersion != nil }

    func start() {
        guard adbURL != nil else { return }
        tracker.start()
        // The companion may change on the phone while the suite is in the background.
        activation = activation ?? NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCompanion() }
        }
    }

    func stop() {
        tracker.stop()
        stopPairing()
    }

    func installPlatformTools() {
        guard downloadProgress == nil else { return }
        downloadProgress = 0
        downloadError = nil
        Task {
            do {
                try await PlatformTools.install { [weak self] value in
                    if self?.downloadProgress != nil { self?.downloadProgress = value }
                }
                adbURL = ADB.executableURL
                tracker.stop()
                start()
            } catch {
                downloadError = "Não foi possível instalar as ferramentas Android: \(error.localizedDescription)"
            }
            downloadProgress = nil
        }
    }

    func refreshCompanion() {
        guard let serial = device?.serial else {
            companionVersion = nil
            return
        }
        Task {
            let version = await Companion.installedVersion(serial: serial)
            if device?.serial == serial { companionVersion = version }
        }
    }

    func installCompanion() {
        guard let serial = device?.serial, let apkURL, !companionBusy else { return }
        companionBusy = true
        companionError = nil
        Task {
            do { try await Companion.install(apk: apkURL, serial: serial) } catch { companionError = error.localizedDescription }
            companionBusy = false
            refreshCompanion()
        }
    }

    func startQRPairing() {
        stopPairing()
        let session = PairingSession.random()
        waitForScan(session)
        pairFinder = finder(Self.pairingType) { [weak self] name, address in
            guard name == session.name else { return }
            self?.pair(address: address, code: session.password)
        }
    }

    func pairManually() {
        pair(address: manualPairAddress.trimmingCharacters(in: .whitespaces), code: manualCode.trimmingCharacters(in: .whitespaces))
    }

    func connectManually() {
        connect(manualConnectAddress.trimmingCharacters(in: .whitespaces))
    }

    func stopPairing() {
        pairFinder?.stop()
        connectFinder?.stop()
        pairFinder = nil
        connectFinder = nil
        scanHint?.cancel()
        connectHint?.cancel()
        pairing = .idle
        pairingMessage = nil
        phoneNotSeen = false
    }

    // Used by the offscreen render only: shows a QR and runs the scan timer without browsing the network.
    func showPairingPreview(_ session: PairingSession) { waitForScan(session) }

    // After 20 s without the phone's advert the Wi-Fi hint shows; the browser keeps looking.
    private func waitForScan(_ session: PairingSession) {
        pairing = .waitingForScan(session)
        scanHint = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.pairing == .waitingForScan(session) else { return }
            self.phoneNotSeen = true
        }
    }

    private func devicesChanged(_ list: [ADBDevice]) {
        let previous = device?.serial
        devices = list
        if device != nil, pairing != .idle { stopPairing() }
        if device?.serial != previous { refreshCompanion() }
    }

    private func pair(address: String, code: String) {
        guard pairing != .pairing, !address.isEmpty, !code.isEmpty else { return }
        pairFinder?.stop()
        pairFinder = nil
        pairing = .pairing
        pairingMessage = nil
        phoneNotSeen = false
        Task {
            do {
                let result = try await ADB.run(["pair", address, code], timeout: 30)
                let output = result.output + result.errorOutput
                guard ADBOutput.pairSucceeded(output) else {
                    pairing = .idle
                    pairingMessage = "Pareamento falhou: \(output.trimmingCharacters(in: .whitespacesAndNewlines)). Tente de novo."
                    return
                }
                startConnecting(guid: ADBOutput.pairedGUID(output), host: String(address.split(separator: ":").first ?? ""))
            } catch {
                pairing = .idle
                pairingMessage = error.localizedDescription
            }
        }
    }

    // adb's own mDNS usually connects right after pairing; the browser covers the case where it does not.
    private func startConnecting(guid: String?, host: String) {
        guard device == nil else { return stopPairing() }
        pairing = .connecting
        connectFinder = finder(Self.connectType) { [weak self] name, address in
            guard name == guid || (guid == nil && address.hasPrefix(host + ":")) else { return }
            self?.connect(address)
        }
        connectHint = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.pairing == .connecting else { return }
            self.pairingMessage = "Pareado, mas ainda sem conexão. Abra \"Parear com código\" e digite o IP e a porta da tela Depuração sem fio."
        }
    }

    private func connect(_ address: String) {
        guard !address.isEmpty else { return }
        Task {
            let result = try? await ADB.run(["connect", address], timeout: 20)
            let output = ((result?.output ?? "") + (result?.errorOutput ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
            if !ADBOutput.connectSucceeded(output) { pairingMessage = "Falha ao conectar em \(address): \(output)" }
        }
    }

    private func finder(_ type: String, onFound: @escaping @MainActor (String, String) -> Void) -> BonjourFinder {
        let finder = BonjourFinder(type: type, onFailure: { [weak self] in self?.pairingMessage = $0 }, onFound: onFound)
        finder.start()
        return finder
    }
}
