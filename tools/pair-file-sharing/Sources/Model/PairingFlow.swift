import AppKit
import CunhaKit
import Foundation

// "Parear celular": new 32-byte key; adb provisioning when the phone is plugged in, QR code otherwise.
@MainActor
final class PairingFlow: ObservableObject {
    enum Step: Equatable {
        case working(String)
        case qr(host: String?)
        case done(String)
    }

    @Published private(set) var step: Step = .working("Procurando o celular pelo adb…")
    @Published private(set) var qrImage: NSImage?
    @Published private(set) var note: String?
    private let center: TransferCenter
    private var key = Data()
    private var task: Task<Void, Never>?

    init(center: TransferCenter) {
        self.center = center
    }

    func begin() {
        task?.cancel()
        key = SecureChannel.randomBytes(32)
        note = nil
        qrImage = nil
        step = .working("Procurando o celular pelo adb…")
        center.setPendingKey(key)
        center.onPairingConfirmed = { [weak self] peer in self?.confirmed(peer) }
        task = Task { await provisionOrShowQR() }
    }

    func end() {
        task?.cancel()
        center.setPendingKey(nil)
        center.onPairingConfirmed = nil
    }

    func showQR(note: String? = nil) {
        let host = LocalAddress.primaryIPv4()
        let link = PairingLink(key: key, macID: MacIdentity.id, macName: MacIdentity.name, host: host, port: Wire.macPort)
        qrImage = QRCode.image(for: link.url.absoluteString)
        self.note = note
        step = .qr(host: host)
    }

    private func provisionOrShowQR() async {
        guard let device = await ADB.preferredDevice() else { return showQR() }
        guard await ADB.isCompanionInstalled(serial: device.serial) else {
            return showQR(note: "O app Cunha Tools não está instalado em \(device.displayName). Instale pelo Cunha Tools ou use o QR.")
        }
        step = .working("Pareando com \(device.displayName) pelo adb…")
        do {
            let phone = try await PhoneADB.provision(serial: device.serial, key: key, macID: MacIdentity.id, macName: MacIdentity.name, host: LocalAddress.primaryIPv4(), port: Wire.macPort)
            guard !Task.isCancelled else { return }
            save(phoneID: phone.id, name: phone.name, host: phone.host, port: Int(Wire.phonePort))
        } catch {
            guard !Task.isCancelled else { return }
            showQR(note: "Pareamento pelo adb falhou (\(error.localizedDescription)). Use o QR.")
        }
    }

    private func confirmed(_ peer: PeerInfo) {
        save(phoneID: peer.id, name: peer.name, host: peer.host, port: peer.port == 0 ? Int(Wire.phonePort) : Int(peer.port))
    }

    private func save(phoneID: String, name: String, host: String?, port: Int) {
        if case .done = step { return }
        let pairedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        center.savePairing(Pairing(key: Base64URL.encode(key), macID: MacIdentity.id, phoneID: phoneID, phoneName: name, phoneHost: host, phonePort: port, pairedAt: pairedAt))
        center.setPendingKey(nil)
        step = .done(name)
    }
}
