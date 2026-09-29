import AppKit
import CoreImage

// Runs the real client (session, decoder, overlay, input) against a fake scrcpy server on a local port.
@MainActor
final class PipelineSelfTest: NSObject, NSApplicationDelegate {
    private static var retained: PipelineSelfTest?

    private let port: UInt16
    private let seconds: Double
    private let outputDirectory: URL
    private let expectedClipboard: String?
    private let capturesEnabled: Bool
    private var controller: MirrorController?
    private var sizes: [(size: CGSize, framesBefore: Int)] = []
    private let latestFrame = FrameBox()
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.marcelocunha.pairscreen.selftest"))

    static func run(arguments: [String]) {
        guard let port = SelfTest.value("--port", in: arguments).flatMap(UInt16.init) else {
            SelfTest.log("uso: --selftest-pipeline --port N [--seconds S] [--out DIR] [--expect-clipboard TEXTO]")
            exit(2)
        }
        let test = PipelineSelfTest(
            port: port,
            seconds: SelfTest.value("--seconds", in: arguments).flatMap(Double.init) ?? 6,
            outputDirectory: URL(fileURLWithPath: SelfTest.value("--out", in: arguments) ?? NSTemporaryDirectory()),
            expectedClipboard: SelfTest.value("--expect-clipboard", in: arguments),
            capturesEnabled: !arguments.contains("--no-capture")
        )
        retained = test
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = test
        app.run()
    }

    private init(port: UInt16, seconds: Double, outputDirectory: URL, expectedClipboard: String?, capturesEnabled: Bool) {
        self.port = port
        self.seconds = seconds
        self.outputDirectory = outputDirectory
        self.expectedClipboard = expectedClipboard
        self.capturesEnabled = capturesEnabled
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let suite = "com.marcelocunha.pairscreen.selftest"
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        pasteboard.clearContents()
        let controller = MirrorController(settings: MirrorSettings(defaults: defaults), launcher: DirectLauncher(port: port), defaults: defaults)
        controller.pasteboard = pasteboard
        controller.onVideoSize = { [weak self] size in self?.sessionChanged(size) }
        self.controller = controller
        controller.connect()
        SelfTest.log("WINDOW_ID=\(controller.overlay.windowNumber)")
        if capturesEnabled { after(1.5) { [weak self] in self?.sendInput() } }
        after(seconds) { [weak self] in self?.finish() }
    }

    private func after(_ delay: Double, _ action: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(action) }
    }

    private func decodedFrames() -> Int { controller?.session?.decoder?.stats.decodedFrames ?? 0 }

    private func sessionChanged(_ size: CGSize) {
        guard let controller else { return }
        let box = latestFrame
        controller.session?.decoder?.onFrame = { box.set($0) }
        sizes.append((size, decodedFrames()))
        let index = sizes.count
        after(0.8) { [weak self] in
            guard let self, let controller = self.controller else { return }
            let frame = controller.overlay.panel.frame
            SelfTest.log("sessão \(index): vídeo \(Int(size.width))x\(Int(size.height)) janela \(Int(frame.width))x\(Int(frame.height)) em (\(Int(frame.minX)),\(Int(frame.minY))) frames=\(self.decodedFrames())")
            if self.capturesEnabled { self.capture(label: "sessao\(index)-\(Int(size.width))x\(Int(size.height))") }
        }
    }

    // Mouse, keyboard and trackpad as NSEvents through the real view, plus text and strip actions; the fake server logs what arrives.
    private func sendInput() {
        guard let controller else { return }
        let view = controller.overlay.root.videoView
        let panel = controller.overlay.panel
        let windowPoint = { (x: CGFloat, y: CGFloat) in view.convert(NSPoint(x: view.bounds.width * x, y: view.bounds.height * y), to: nil) }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func key(_ type: NSEvent.EventType, _ characters: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, windowPoint(0.5, 0.5)))
        view.mouseDragged(with: mouse(.leftMouseDragged, windowPoint(0.5, 0.25)))
        view.mouseUp(with: mouse(.leftMouseUp, windowPoint(0.5, 0.25)))
        view.rightMouseDown(with: mouse(.rightMouseDown, windowPoint(0.1, 0.9)))
        view.rightMouseUp(with: mouse(.rightMouseUp, windowPoint(0.1, 0.9)))
        view.keyDown(with: key(.keyDown, "a", 0))
        view.keyUp(with: key(.keyUp, "a", 0))
        view.keyDown(with: key(.keyDown, "\r", 36, .shift))
        view.keyUp(with: key(.keyUp, "\r", 36, .shift))
        _ = view.performKeyEquivalent(with: key(.keyDown, "a", 0, .command))
        if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -40, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)) {
            view.scrollWheel(with: scroll)
        }
        controller.router.insertText("oi é ç")
        pasteboard.clearContents()
        pasteboard.setString("colado do Mac", forType: .string)
        _ = view.performKeyEquivalent(with: key(.keyDown, "v", 9, .command))
        controller.perform(.rotate)
        SelfTest.log("entrada simulada enviada (first responder = vídeo: \(panel.firstResponder === view))")
        after(1.8) { [weak self] in
            self?.controller?.hideOverlay()
            SelfTest.log("janela oculta: decodificação pausada")
        }
        after(2.3) { [weak self] in
            guard let self else { return }
            let before = self.controller?.session?.decoder?.stats
            self.controller?.showOverlay()
            SelfTest.log("janela visível: frames=\(before?.decodedFrames ?? 0) descartados na pausa=\(before?.droppedFrames ?? 0)")
        }
    }

    // Real capture of the on-screen window (needs an unlocked session), plus the frame the display layer is showing.
    private func capture(label: String) {
        guard let controller else { return }
        let url = outputDirectory.appendingPathComponent("janela-\(label).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(controller.overlay.windowNumber)", url.path]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        SelfTest.log("screencapture \(process.terminationStatus == 0 ? url.path : "indisponível (sessão bloqueada ou sem permissão)")")
        let renderer = controller.overlay.renderer
        let displayed = renderer.displayedPixelBuffer()
        SelfTest.log("renderer: status=\(renderer.status == .rendering ? "rendering" : "\(renderer.status.rawValue)") erro=\(renderer.error?.localizedDescription ?? "nenhum") frame exibido=\(displayed.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "indisponível")")
        guard let frame = displayed ?? latestFrame.get() else { return }
        OverlaySnapshot.write(root: controller.overlay.root, frame: frame, to: outputDirectory.appendingPathComponent("overlay-\(label).png"))
    }

    private func finish() {
        guard let controller else { exit(1) }
        let stats = controller.session?.decoder?.stats ?? DecoderStats()
        SelfTest.log("codec=\(controller.session?.decoder?.codec.label ?? "-") frames decodificados=\(stats.decodedFrames) descartados=\(stats.droppedFrames) erros=\(stats.decodeErrors) trocas de formato=\(stats.formatChanges) hardware=\(stats.hardware ? "sim" : "não")")
        SelfTest.log("sessões de vídeo: " + sizes.map { "\(Int($0.size.width))x\(Int($0.size.height))@\($0.framesBefore)" }.joined(separator: ", "))
        SelfTest.log("conexões com vídeo: \(sizes.filter { $0.framesBefore == 0 }.count)")
        if let note = controller.note { SelfTest.log("aviso: \(note)") }
        var ok = stats.decodedFrames > 0 && stats.decodeErrors == 0
        if let expectedClipboard {
            let received = pasteboard.string(forType: .string)
            SelfTest.log("clipboard recebido do celular: \(received ?? "nenhum")")
            ok = ok && received == expectedClipboard
        }
        controller.disconnect()
        SelfTest.log(ok ? "RESULTADO=ok" : "RESULTADO=falha")
        pasteboard.releaseGlobally()
        exit(ok ? 0 : 1)
    }
}

final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CVImageBuffer?
    func set(_ value: CVImageBuffer) { lock.withLock { frame = value } }
    func get() -> CVImageBuffer? { lock.withLock { frame } }
}
