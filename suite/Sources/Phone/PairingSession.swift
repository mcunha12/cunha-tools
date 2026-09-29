import AppKit

// The QR that Android's "Parear o dispositivo com um código QR" scans, same format as Android Studio.
struct PairingSession: Equatable, Sendable {
    let name: String
    let password: String

    var payload: String { "WIFI:T:ADB;S:\(name);P:\(password);;" }

    static func random() -> PairingSession {
        PairingSession(name: "cunha-" + randomString(10), password: randomString(12))
    }

    // Letters and digits only, so nothing needs escaping in the WIFI: payload.
    private static func randomString(_ length: Int) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    func qrImage(scale: CGFloat = 8) -> NSImage? { QRCode.image(payload, scale: scale) }
}
