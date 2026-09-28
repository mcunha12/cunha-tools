import AppKit
import Combine
import CoreAudio
import CunhaKit

@MainActor
final class AppModel: ObservableObject {
    private static let silenceGracePeriod: TimeInterval = 3

    @Published private(set) var audibleApps: [AppItem] = []
    @Published private(set) var settings: VolumeSettingsStore
    @Published private(set) var permission = AudioCapturePermission.status {
        didSet {
            if permission != oldValue { ToolStatus.publish(setupComplete: permission == .authorized) }
        }
    }
    @Published private(set) var failures: [String: String] = [:]

    let master: MasterVolume
    private(set) var apps: [AppItem] = []
    private var lastPlayingAt: [String: Date] = [:]
    private let scan: () -> [AppItem]
    private let router = AudioRouter()
    private var outputWatcher: ProcessOutputWatcher?
    private var isRequestingPermission = false
    private var isRefreshScheduled = false
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, master: MasterVolume? = nil, scan: @escaping () -> [AppItem] = RunningAppsScanner.scan) {
        settings = VolumeSettingsStore(defaults: defaults, key: VolumeSettingsStore.appsKey)
        self.master = master ?? MasterVolume(defaults: defaults)
        self.scan = scan
        outputWatcher = ProcessOutputWatcher { [weak self] in self?.scheduleRefresh() }
        refresh()
        self.master.onChange = { [weak self] in self?.applyRoutes() }
        AudioObjectID.system.onChange(of: kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.refresh() }
        AudioObjectID.system.onChange(of: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.refresh() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    var ceiling: Double { master.level.volume }

    func setting(for app: AppItem) -> VolumeSetting {
        settings[app.id]
    }

    func effectiveVolume(for app: AppItem) -> Double {
        VolumeCeiling.effectiveVolume(settings[app.id].volume, ceiling: ceiling)
    }

    func gain(for app: AppItem) -> Float {
        VolumeCeiling.gain(app: settings[app.id], master: master.level, decibels: master.decibelCurve)
    }

    func setVolume(_ volume: Double, for app: AppItem) {
        let stored = VolumeCeiling.storedVolume(dragged: volume, ceiling: ceiling)
        update(app) { $0.volume = stored; if stored > 0 { $0.muted = false } }
    }

    func toggleMute(for app: AppItem) {
        update(app) { $0.muted.toggle() }
    }

    func requestPermissionIfNeeded() {
        if permission == .unknown { requestPermission() }
    }

    func requestPermission() {
        if permission == .denied {
            AudioCapturePermission.openSystemSettings()
            return
        }
        guard !isRequestingPermission else { return }
        isRequestingPermission = true
        AudioCapturePermission.request { [weak self] granted in
            guard let self else { return }
            isRequestingPermission = false
            permission = granted ? .authorized : .denied
            applyRoutes()
        }
    }

    func shutdown() {
        router.stopAll()
    }

    private func update(_ app: AppItem, _ change: (inout VolumeSetting) -> Void) {
        var setting = settings[app.id]
        change(&setting)
        settings[app.id] = setting
        if permission != .authorized, !setting.isDefault {
            requestPermission()
        }
        applyRoutes()
    }

    private func scheduleRefresh() {
        guard !isRefreshScheduled else { return }
        isRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isRefreshScheduled = false
                self?.refresh()
            }
        }
    }

    private func refresh() {
        apps = scan()
        outputWatcher?.watch(Set(apps.flatMap(\.audioProcessIDs)))
        publishAudibleApps()
        syncPermission()
        applyRoutes()
    }

    private func publishAudibleApps() {
        let now = Date()
        for app in apps where app.isPlaying { lastPlayingAt[app.id] = now }
        lastPlayingAt = lastPlayingAt.filter { now.timeIntervalSince($0.value) < Self.silenceGracePeriod }
        let audible = apps.filter { lastPlayingAt[$0.id] != nil }
        if audible != audibleApps { audibleApps = audible }
    }

    private func syncPermission() {
        let status = AudioCapturePermission.status
        if status != .unknown, status != permission { permission = status }
    }

    // A software main volume taps only the apps playing sound, besides apps with their own setting.
    private func applyRoutes() {
        guard permission == .authorized else {
            router.stopAll()
            return
        }
        let requests = apps.compactMap { app -> RouteRequest? in
            guard !app.audioProcessIDs.isEmpty, !settings[app.id].isDefault || lastPlayingAt[app.id] != nil else { return nil }
            return RouteRequest(key: app.id, processObjectIDs: app.audioProcessIDs, gain: gain(for: app), keepsTap: !settings[app.id].isDefault)
        }
        router.apply(requests)
        if router.failures != failures { failures = router.failures }
    }
}
