import AppKit
import CunhaKit

enum MirrorState: Equatable {
    case idle
    case connecting
    case streaming
    case reconnecting
    case noDevice
    case failed(String)
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

// Connection lifecycle: launch server, open sockets, stream, reconnect when the phone drops and comes back.
@MainActor
final class MirrorController: ObservableObject {
    @Published private(set) var state: MirrorState = .idle
    @Published private(set) var deviceName: String?
    @Published private(set) var availableDevice: String?
    @Published private(set) var overlayVisible = false
    @Published private(set) var screenOn = true
    @Published private(set) var note: String?

    let settings: MirrorSettings
    let router = InputRouter()
    private(set) lazy var overlay = makeOverlay()
    private let launcher: ServerLauncher
    private let defaults: UserDefaults
    private(set) var session: MirrorSession?
    private var server: LaunchedServer?
    private var activeOptions: StreamOptions?
    private var attempt = 0
    private var connectFlag = CancelFlag()
    private var wantsConnection = false
    private var hasStreamed = false
    private var lastSerial: String?
    private var h264Only: Set<String> = []
    private var lastCodecSetting: VideoCodec
    private var lastTurnScreenOff: Bool
    private var reconnectDelay: TimeInterval = 1
    private var reconnectTask: Task<Void, Never>?
    private var watchdog: Timer?

    var onVideoSize: ((CGSize) -> Void)?
    var pasteboard: NSPasteboard = .general {
        didSet { router.pasteboard = pasteboard }
    }

    init(settings: MirrorSettings, launcher: ServerLauncher = AdbServerLauncher(), defaults: UserDefaults = .standard) {
        self.settings = settings
        self.launcher = launcher
        self.defaults = defaults
        lastCodecSetting = settings.codec
        lastTurnScreenOff = settings.turnScreenOff
        settings.onChange = { [weak self] in self?.settingsChanged() }
    }

    var isActive: Bool { wantsConnection }

    // The window opens when the first session starts, so a missing phone does not flash an empty overlay.
    func connect() {
        guard !wantsConnection else { return showOverlay() }
        overlayVisible = true
        wantsConnection = true
        hasStreamed = false
        reconnectDelay = 1
        note = nil
        begin(reconnecting: false)
    }

    func disconnect() {
        wantsConnection = false
        reconnectTask?.cancel()
        teardown()
        overlay.hide()
        overlayVisible = false
        deviceName = nil
        state = .idle
    }

    func toggleOverlay() {
        if overlayVisible { hideOverlay() } else { showOverlay() }
    }

    func showOverlay() {
        overlayVisible = true
        overlay.setAlwaysOnTop(settings.alwaysOnTop)
        overlay.show()
        session?.setVideoPaused(false)
    }

    func hideOverlay() {
        overlayVisible = false
        overlay.hide()
        session?.setVideoPaused(true)
    }

    func perform(_ action: StripAction) {
        switch action {
        case .back: router.pressBack()
        case .home: router.press(AndroidKeycode.home)
        case .recents: router.press(AndroidKeycode.appSwitch)
        case .toggleScreen: setScreen(on: !screenOn)
        case .rotate: session?.send(.rotateDevice)
        case .close: disconnect()
        }
    }

    func openSuite() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SuitePaths.suiteBundleID) else {
            note = "Cunha Tools não encontrado em Aplicativos."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func refreshDevice() async {
        let device = await ADB.preferredDevice()
        availableDevice = device?.displayName
        ToolStatus.publish(setupComplete: device != nil)
        if device != nil, state == .noDevice { state = .idle }
    }

    private func makeOverlay() -> OverlayWindowController {
        let controller = OverlayWindowController(router: router, defaults: defaults)
        controller.root.strip.onAction = { [weak self] in self?.perform($0) }
        return controller
    }

    private func effectiveOptions() -> StreamOptions {
        var options = settings.streamOptions
        if h264Only.contains(lastSerial ?? "") { options.codec = .h264 }
        return options
    }

    private func begin(reconnecting: Bool) {
        attempt += 1
        let token = attempt
        let flag = CancelFlag()
        connectFlag = flag
        state = reconnecting ? .reconnecting : .connecting
        overlay.setStatus(reconnecting ? "Reconectando…" : "Conectando…")
        let options = effectiveOptions()
        Task { await run(token: token, options: options, flag: flag) }
    }

    private func run(token: Int, options: StreamOptions, flag: CancelFlag) async {
        let reconnecting = state == .reconnecting
        do {
            let server = try await launcher.launch(options: options, preferredSerial: lastSerial)
            guard token == attempt else { return await server.stop() }
            self.server = server
            if let serial = server.serial { lastSerial = serial }
            let connection = try await ServerConnection.open(port: server.port) { !flag.isCancelled && server.isAlive }
            await server.removeForward()
            guard token == attempt else {
                connection.video.shutdown()
                connection.control.shutdown()
                return await server.stop()
            }
            start(connection, options: options, token: token)
        } catch {
            guard token == attempt else { return }
            let failed = server
            server = nil
            let log = failed?.recentLog ?? ""
            await failed?.stop()
            guard token == attempt else { return }
            handleFailure(error, log: log, reconnecting: reconnecting)
        }
    }

    private func handleFailure(_ error: Error, log: String, reconnecting: Bool) {
        if reconnecting { return scheduleReconnect() }
        wantsConnection = false
        overlay.hide()
        overlayVisible = false
        if case LaunchError.noDevice = error {
            ToolStatus.publish(setupComplete: false)
            availableDevice = nil
            state = .noDevice
            return
        }
        state = .failed(error.localizedDescription + Self.serverError(in: log))
    }

    private static func serverError(in log: String) -> String {
        log.split(whereSeparator: \.isNewline).last { $0.contains("ERROR") }.map { " \($0)" } ?? ""
    }

    private func start(_ connection: ServerConnection, options: StreamOptions, token: Int) {
        let events = SessionEvents(
            onVideoSize: { [weak self] size in self?.videoSizeChanged(size, token: token) },
            onClipboard: { [weak self] text in self?.receivedClipboard(text) },
            onEnd: { [weak self] reason, frames in self?.sessionEnded(reason: reason, frames: frames, token: token) }
        )
        let session = MirrorSession(connection: connection, renderer: overlay.renderer, events: events)
        self.session = session
        activeOptions = options
        router.session = session
        deviceName = connection.deviceName
        availableDevice = connection.deviceName
        overlay.setTitle(connection.deviceName)
        overlay.setStatus(nil)
        state = .streaming
        reconnectDelay = 1
        session.setVideoPaused(!overlayVisible)
        session.start()
        if overlayVisible { showOverlay() }
        screenOn = true
        if settings.turnScreenOff { setScreen(on: false) }
        overlay.root.strip.setScreenOn(screenOn)
        ToolStatus.publish(setupComplete: true)
        startWatchdog(token: token)
    }

    private func videoSizeChanged(_ size: CGSize, token: Int) {
        guard token == attempt else { return }
        overlay.apply(videoSize: size)
        onVideoSize?(size)
    }

    private func receivedClipboard(_ text: String) {
        guard pasteboard.string(forType: .string) != text else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func sessionEnded(reason: SessionEnd, frames: Int, token: Int) {
        guard token == attempt, session != nil else { return }
        NSLog("PairScreen: sessão encerrada (\(reason)), frames recebidos=\(frames)")
        let codec = activeOptions?.codec
        let log = server?.recentLog ?? ""
        teardown()
        guard wantsConnection else {
            state = .idle
            return
        }
        if frames > 0 { hasStreamed = true }
        let key = lastSerial ?? ""
        if frames == 0, !hasStreamed, codec == .h265, !h264Only.contains(key) {
            h264Only.insert(key)
            note = "H.265 indisponível neste celular; usando H.264."
            return begin(reconnecting: false)
        }
        if frames == 0, !hasStreamed {
            wantsConnection = false
            hideOverlay()
            state = .failed("O celular não enviou vídeo." + Self.serverError(in: log))
            return
        }
        state = .reconnecting
        overlay.setStatus("Reconectando…")
        scheduleReconnect()
    }

    private func teardown() {
        attempt += 1
        connectFlag.cancel()
        watchdog?.invalidate()
        watchdog = nil
        session?.stop()
        session = nil
        router.session = nil
        activeOptions = nil
        if let server {
            self.server = nil
            server.terminateProcess()
            Task { await server.stop() }
        }
    }

    private func scheduleReconnect() {
        state = .reconnecting
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 15)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, wantsConnection, session == nil else { return }
            begin(reconnecting: true)
        }
    }

    // No video for 10 s: ask adb whether the phone is still online, and reconnect if it is gone.
    private func startWatchdog(token: Int) {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStalled(token: token) }
        }
    }

    private func checkStalled(token: Int) {
        guard token == attempt, let session, session.secondsSinceLastData > 10, let serial = lastSerial else { return }
        Task {
            let online = (try? await ADB.devices())?.contains { $0.serial == serial && $0.isOnline } ?? false
            guard !online, token == attempt, wantsConnection else { return }
            teardown()
            overlay.setStatus("Reconectando…")
            scheduleReconnect()
        }
    }

    private func setScreen(on: Bool) {
        guard let session else { return }
        session.send(.setDisplayPower(on: on))
        screenOn = on
        overlay.root.strip.setScreenOn(on)
    }

    private func settingsChanged() {
        overlay.setAlwaysOnTop(settings.alwaysOnTop)
        if settings.codec != lastCodecSetting {
            lastCodecSetting = settings.codec
            h264Only.removeAll()
        }
        if settings.turnScreenOff != lastTurnScreenOff {
            lastTurnScreenOff = settings.turnScreenOff
            setScreen(on: !settings.turnScreenOff)
        }
        guard session != nil else { return }
        if let active = activeOptions, effectiveOptions() != active {
            teardown()
            begin(reconnecting: false)
        }
    }
}
