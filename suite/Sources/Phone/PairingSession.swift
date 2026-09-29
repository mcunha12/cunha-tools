import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

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

    func qrImage(scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
