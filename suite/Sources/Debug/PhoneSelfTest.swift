import AppKit
import CoreImage
import CunhaKit

@MainActor
enum PhoneSelfTest {
    static func run(_ checker: Checker) async {
        checkQR(checker)
        checkParsers(checker)
        checkTrackFrames(checker)
    }

    // Real download from Google into a test folder, then `adb version` from the extracted copy.
    static func platformTools(into folder: URL, checker: Checker) async {
        let destination = folder.appendingPathComponent("platform-tools", isDirectory: true)
        var reported = -1
        let started = Date()
        do {
            try await PlatformTools.install(into: destination) { progress in
                let step = Int(progress * 4)
                if step > reported { reported = step; SelfTest.log("download \(step * 25)%") }
            }
        } catch {
            return checker.fail("download/extração: \(error.localizedDescription)")
        }
        SelfTest.log(String(format: "download + extração em %.1f s", Date().timeIntervalSince(started)))
        let adb = destination.appendingPathComponent("adb")
        checker.check(FileManager.default.isExecutableFile(atPath: adb.path), "adb extraído em \(adb.path)")
        let process = Process()
        process.executableURL = adb
        process.arguments = ["version"]
        let result = try? await runProcess(process, timeout: 15)
        let firstLines = result?.output.split(whereSeparator: \.isNewline).prefix(2).joined(separator: " | ") ?? "-"
        checker.check(result?.output.contains("Android Debug Bridge") == true, "adb version: \(firstLines)")
    }

    // Publishes a fake pairing service on this Mac and expects BonjourFinder to resolve it, like a phone showing the QR screen.
    static func bonjour(_ checker: Checker) async {
        let name = "cunha-selftest-\(getpid())"
        let port = 45678
        let service = NetService(domain: "local.", type: PhoneModel.pairingType + ".", name: name, port: Int32(port))
        service.publish()
        defer { service.stop() }
        let outcome = Outcome()
        let finder = BonjourFinder(type: PhoneModel.pairingType, onFailure: { outcome.failure = $0 }) { found, address in
            if found == name { outcome.address = address }
        }
        finder.start()
        let deadline = Date().addingTimeInterval(10)
        while outcome.address == nil, outcome.failure == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        finder.stop()
        let result = outcome.address ?? outcome.failure ?? "nada em 10 s"
        checker.check(outcome.address?.hasSuffix(":\(port)") == true, "Bonjour: NWBrowser acha o serviço e NetService resolve \(result)")
    }

    private static func checkQR(_ checker: Checker) {
        let fixed = PairingSession(name: "cunha-abc", password: "Xyz123")
        checker.check(fixed.payload == "WIFI:T:ADB;S:cunha-abc;P:Xyz123;;", "QR: payload no formato do Android Studio")
        let session = PairingSession.random()
        let alphanumeric = CharacterSet.alphanumerics
        checker.check(session.name.hasPrefix("cunha-") && session.name.count == 16 && session.password.count == 12, "QR: nome e senha aleatórios")
        checker.check(session.password.unicodeScalars.allSatisfy(alphanumeric.contains) && session != PairingSession.random(), "QR: senha só com letras e dígitos, nova a cada sessão")
        guard let image = session.qrImage(), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return checker.fail("QR: imagem não gerada")
        }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let decoded = detector?.features(in: CIImage(cgImage: cgImage)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
        checker.check(decoded == session.payload, "QR: imagem \(cgImage.width)px decodifica para o payload")
    }

    private static func checkParsers(_ checker: Checker) {
        let paired = "Successfully paired to 192.168.0.10:37891 [guid=adb-R5CT3ABC-Qw12Er]\n"
        checker.check(ADBOutput.pairSucceeded(paired) && ADBOutput.pairedGUID(paired) == "adb-R5CT3ABC-Qw12Er", "pair: sucesso e guid do serviço de conexão")
        checker.check(!ADBOutput.pairSucceeded("Failed: Wrong password or connection was dropped."), "pair: falha reconhecida")
        checker.check(ADBOutput.connectSucceeded("connected to 192.168.0.10:40000") && ADBOutput.connectSucceeded("already connected to 192.168.0.10:40000"), "connect: sucesso")
        checker.check(!ADBOutput.connectSucceeded("failed to connect to 192.168.0.10:40000") && !ADBOutput.connectSucceeded("cannot connect to 192.168.0.10:40000: Connection refused"), "connect: falha reconhecida")
        let dumpsys = """
        Packages:
          Package [com.other.app] (1a2b):
            versionName=9.9.9
          Package [com.marcelocunha.cunhatools] (3c4d):
            versionCode=3 minSdk=26 targetSdk=35
            versionName=0.1.0
        """
        checker.check(ADBOutput.versionName(dumpsys: dumpsys, package: ADB.companionPackage) == "0.1.0", "dumpsys: versionName do app companheiro")
        checker.check(ADBOutput.versionName(dumpsys: "Unable to find package: \(ADB.companionPackage)", package: ADB.companionPackage) == nil, "dumpsys: pacote ausente")
        checker.check(ADBOutput.installBlocked("adb: failed to install a.apk: Failure [INSTALL_FAILED_USER_RESTRICTED: Install canceled by user]"), "install: bloqueio reconhecido")
        checker.check(!ADBOutput.installBlocked("adb: failed to install a.apk: Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"), "install: outra falha não vira bloqueio")
    }

    private static func checkTrackFrames(_ checker: Checker) {
        let listing = "R5CT3ABC\tdevice usb:1-1 product:dm3qxxx model:SM_S918B device:dm3q transport_id:3\n192.168.0.10:40000\tunauthorized transport_id:4\n"
        let frame = String(format: "%04x", listing.utf8.count) + listing
        var buffer = Data(("0000" + frame).utf8)
        let tail = buffer.suffix(10)
        buffer = Data(buffer.dropLast(10))
        let first = ADBOutput.takeTrackFrames(&buffer)
        checker.check(first.count == 1 && first[0].isEmpty, "track-devices: lista vazia e frame parcial aguardado")
        buffer.append(tail)
        let second = ADBOutput.takeTrackFrames(&buffer)
        let devices = second.first ?? []
        checker.check(second.count == 1 && buffer.isEmpty && devices.count == 2, "track-devices: frame completo com 2 aparelhos")
        checker.check(devices.first?.model == "SM_S918B" && devices.first?.isOnline == true && devices.first?.isWireless == false, "track-devices: modelo e USB")
        checker.check(devices.last?.isOnline == false && devices.last?.isWireless == true, "track-devices: Wi-Fi não autorizado")
    }
}

@MainActor
private final class Outcome {
    var address: String?
    var failure: String?
}
