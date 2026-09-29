import AppKit
import CoreImage
import CryptoKit
import CunhaKit
import Foundation
import SwiftUI

// Headless checks: --selftest-receive, --selftest-send, --selftest-wrongkey, --selftest-crypto, --selftest-unit, --selftest-bonjour, --selftest-render. Exit code 0 means pass.
enum SelfTest {
    static func runIfRequested() -> Int32? {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first, command.hasPrefix("--selftest-") else { return nil }
        let rest = Array(arguments.dropFirst())
        do {
            switch command {
            case "--selftest-receive": return try receive(port: UInt16(rest[0])!, key: key(rest[1]), folder: URL(fileURLWithPath: rest[2]))
            case "--selftest-send": return try send(host: rest[0], port: UInt16(rest[1])!, key: key(rest[2]), connections: Int(rest[3])!, paths: Array(rest.dropFirst(4)))
            case "--selftest-wrongkey": return wrongKey(host: rest[0], port: UInt16(rest[1])!, key: try key(rest[2]))
            case "--selftest-crypto": return crypto()
            case "--selftest-unit": return unit()
            case "--selftest-bonjour": return bonjour(seconds: Double(rest.first ?? "4") ?? 4)
            case "--selftest-render": return MainActor.assumeIsolated { render(to: URL(fileURLWithPath: rest[0])) }
            default:
                log("comando desconhecido: \(command)")
                return 2
            }
        } catch {
            log("falhou: \(error.localizedDescription)")
            return 1
        }
    }

    private static func key(_ text: String) throws -> Data {
        guard let data = Base64URL.decode(text), data.count == 32 else { throw TransferError("chave inválida") }
        return data
    }

    // Serves exactly one transfer and prints MB/s.
    private static func receive(port: UInt16, key: Data, folder: URL) throws -> Int32 {
        let done = DispatchSemaphore(value: 0)
        let outcome = SelfTestOutcome()
        let keyID = SecureChannel.keyID(for: key)
        var events = TransferServer.Events()
        events.started = { log("recebendo \($0.entries.count) itens, \($0.total) bytes de \($0.peer.name)") }
        events.ended = { session, error in
            let seconds = Date().timeIntervalSince(session.startedAt)
            if error == nil {
                print(String(format: "recebido: %d itens, %lld bytes em %.2f s = %.0f MB/s", session.entries.count, session.total, seconds, Double(session.total) / seconds / 1e6))
            }
            outcome.set(error)
            done.signal()
        }
        let server = TransferServer(port: port, role: Wire.roleMac, id: "selftest-mac", name: "Mac (autoteste)", sink: FolderSink(root: folder), keys: { $0 == keyID ? key : nil }, events: events)
        try server.start()
        log("ouvindo na porta \(server.port)")
        done.wait()
        server.stop()
        if let error = outcome.get() {
            log("falhou: \(error)")
            return 1
        }
        return 0
    }

    private static func send(host: String, port: UInt16, key: Data, connections: Int, paths: [String]) throws -> Int32 {
        let items = OutgoingItem.collect(paths.map { URL(fileURLWithPath: $0) })
        let sender = TransferSender(key: key, role: Wire.roleMac, id: "selftest-mac", name: "Mac (autoteste)")
        let result = try sender.send(host: host, port: port, items: items, connections: connections)
        print(String(format: "enviado: %d itens, %lld bytes em %.2f s = %.0f MB/s (%d conexões)", result.files, result.bytes, result.seconds, result.megabytesPerSecond, connections))
        return 0
    }

    // Both must fail: an unknown key id, and a known key id presented with the wrong key.
    private static func wrongKey(host: String, port: UInt16, key: Data) -> Int32 {
        var rejected = 0
        let wrong = SecureChannel.randomBytes(32)
        for (label, keyID) in [("chave desconhecida", nil), ("chave errada com id conhecido", SecureChannel.keyID(for: key))] {
            do {
                let channel = try SecureChannel.connect(host: host, port: port, timeout: 2, key: wrong, keyID: keyID, role: Wire.roleMac)
                channel.close()
                print("ERRO: \(label) aceita")
            } catch is AuthError {
                print("\(label) rejeitada")
                rejected += 1
            } catch {
                print("ERRO: \(label): \(error.localizedDescription)")
            }
        }
        return rejected == 2 ? 0 : 1
    }

    private static func crypto() -> Int32 {
        let key = SymmetricKey(size: .bits256)
        let frame = Data(repeating: 7, count: Wire.maxData)
        let frames = 1024
        for threads in [1, 4] {
            let started = Date()
            DispatchQueue.concurrentPerform(iterations: threads) { worker in
                for i in 0..<(frames / threads) {
                    var nonce = [UInt8](repeating: 0, count: 12)
                    nonce[0] = UInt8(worker)
                    withUnsafeBytes(of: UInt64(i).bigEndian) { for b in 0..<8 { nonce[4 + b] = $0[b] } }
                    let box = try! AES.GCM.seal(frame, using: key, nonce: try! AES.GCM.Nonce(data: nonce))
                    _ = try! AES.GCM.open(box, using: key)
                }
            }
            let seconds = Date().timeIntervalSince(started)
            print(String(format: "AES-256-GCM seal+open, %d thread(s): %.0f MB/s", threads, Double(frames * Wire.maxData) / seconds / 1e6))
        }
        return 0
    }

    // Popover (paired, one send, one result), popover (not paired) and the QR step of the pairing window, side by side in a PNG.
    @MainActor
    private static func render(to output: URL) -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let paired = TransferCenter()
        let pairing = Pairing(key: Base64URL.encode(SecureChannel.randomBytes(32)), macID: "mac", phoneID: "phone", phoneName: "Galaxy S25 Ultra", pairedAt: Date())
        var transfer = Transfer(id: "1", direction: .send, title: "Enviando 3 itens", total: 1_800_000_000, done: 620_000_000)
        transfer.bytesPerSecond = 87_400_000
        paired.preview(pairing: pairing, transfers: [transfer], outcome: nil)
        let idle = TransferCenter()
        idle.preview(pairing: pairing, transfers: [], outcome: Outcome(text: "Recebido de Galaxy S25 Ultra: 12 itens, 2,4 GB em 31 s (77 MB/s)", isError: false, urls: [URL(fileURLWithPath: "/tmp")]))
        let unpaired = TransferCenter()
        let flow = PairingFlow(center: unpaired)
        flow.showQR()
        let launch = LaunchAtLogin()
        let root = HStack(alignment: .top, spacing: 16) {
            PopoverView(openPairing: {}).environmentObject(paired).environmentObject(launch)
            PopoverView(openPairing: {}).environmentObject(idle).environmentObject(launch)
            PopoverView(openPairing: {}).environmentObject(unpaired).environmentObject(launch)
            PairingView(flow: flow, close: {})
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1500, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            hosting.layoutSubtreeIfNeeded()
            let bounds = hosting.bounds
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { exit(1) }
            hosting.cacheDisplay(in: bounds, to: bitmap)
            let saved = (try? bitmap.representation(using: .png, properties: [:])?.write(to: output)) != nil
            exit(saved ? 0 : 1)
        }
        application.run()
        return 0
    }

    // Advertises a test instance, browses for it and resolves it to IPv4 + port through dns_sd.
    private static func bonjour(seconds: Double) -> Int32 {
        let id = "selftest-\(getpid())"
        let advertiser = BonjourAdvertiser()
        let browser = BonjourBrowser()
        advertiser.start(name: "Pair File Sharing autoteste \(getpid())", port: 47999, txt: ["role": "phone", "id": id])
        browser.start()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let peer = browser.peer(id: id) {
                print("bonjour: \(peer.id) em \(peer.host):\(peer.port) role=\(peer.role)")
                advertiser.stop()
                return peer.port == 47999 ? 0 : 1
            }
            usleep(100_000)
        }
        print("bonjour: instância não encontrada em \(seconds) s")
        return 1
    }

    private static func unit() -> Int32 {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "ok" : "FALHA"): \(label)")
            if !condition { failures += 1 }
        }
        check((try? RelativePath.clean("a/./b//c.txt")) == "a/b/c.txt", "caminho normalizado")
        check((try? RelativePath.clean("../etc/passwd")) == nil, "caminho com .. rejeitado")
        check((try? RelativePath.clean("/abs/x")) == "abs/x", "caminho absoluto vira relativo")
        check(RelativePath.numbered("foto.jpg", 2, isDirectory: false) == "foto (2).jpg", "nome numerado com extensão")
        check(RelativePath.numbered("Fotos.2024", 3, isDirectory: true) == "Fotos.2024 (3)", "pasta numerada")
        var taken = Set<String>()
        let names = ["a/x.txt", "a/x.txt", "a/x.txt"].map { RelativePath.unique($0, taken: &taken, isDirectory: false) }
        check(names == ["a/x.txt", "a/x (2).txt", "a/x (3).txt"], "nomes repetidos no manifesto")
        let key = SecureChannel.randomBytes(32)
        check(Base64URL.decode(Base64URL.encode(key)) == key, "base64url ida e volta")
        let link = PairingLink(key: key, macID: "mac-1", macName: "Mac de Teste", host: "192.168.1.10", port: Wire.macPort).url
        check(link.scheme == "cunhatools" && link.host == "pair", "link de pareamento")
        check(qrPayload(QRCode.image(for: link.absoluteString)) == link.absoluteString, "QR decodificado devolve o link")
        let plus = PairingLink(key: key, macID: "m", macName: "Mac+Pro de Ana", host: nil, port: Wire.macPort).url
        check(URLComponents(url: plus, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "n" }?.value == "Mac+Pro de Ana" && !plus.absoluteString.contains("+"), "'+' codificado no link")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pfs-unit-\(getpid()).json")
        let pairing = Pairing(key: Base64URL.encode(key), macID: "mac-1", pairedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let saved = (try? PairingStore.save(pairing, to: temp)) != nil
        let mode = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.posixPermissions] as? NSNumber)?.intValue
        check(saved && mode == 0o600, "pairing.json com permissão 0600")
        check(PairingStore.load(from: temp) == pairing, "pairing.json relido")
        try? FileManager.default.removeItem(at: temp)
        return failures == 0 ? 0 : 1
    }

    private static func qrPayload(_ image: NSImage?) -> String? {
        guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil) else { return nil }
        return (detector.features(in: CIImage(cgImage: cgImage)).first as? CIQRCodeFeature)?.messageString
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("selftest: \(message)\n".utf8))
    }
}

private final class SelfTestOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var error: String?
    func set(_ value: String?) { lock.withLock { error = value } }
    func get() -> String? { lock.withLock { error } }
}
