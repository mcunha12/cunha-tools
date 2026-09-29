import AppKit
import CunhaKit

@MainActor
final class ToolsModel: ObservableObject {
    enum Phase { case notInstalled, installed, updateAvailable }

    struct Entry: Identifiable {
        let tool: ToolBundle
        var installed: ToolBundle?
        var isRunning: Bool
        var status: ToolStatus?

        var id: String { tool.bundleID }

        var phase: Phase {
            guard let installed else { return .notInstalled }
            return installed.version < tool.version ? .updateAvailable : .installed
        }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var busy: [String: String] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private var pendingLogin: [String: Bool] = [:]

    private let tools: [ToolBundle]
    private var watcher: DirectoryWatcher?
    private var observers: [NSObjectProtocol] = []

    init(tools: [ToolBundle] = ToolCatalog.load()) {
        self.tools = tools
        refresh()
        watcher = DirectoryWatcher(url: SuitePaths.status) { [weak self] in self?.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self, let bundleID, self.tools.contains(where: { $0.bundleID == bundleID }) else { return }
                    self.refresh()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
    }

    var needsPhone: Bool { tools.contains { $0.requirements.contains(.phone) } }

    func refresh() {
        entries = tools.map { tool in
            Entry(tool: tool, installed: InstallLocation.installedCopy(of: tool), isRunning: RunningTool.isRunning(tool.bundleID), status: ToolStatus.read(bundleID: tool.bundleID))
        }
        for (bundleID, wanted) in pendingLogin {
            guard let status = entries.first(where: { $0.id == bundleID })?.status else { continue }
            if status.launchAtLogin == wanted || (wanted && status.needsApproval) { pendingLogin[bundleID] = nil }
        }
    }

    // Shows the requested value until the tool confirms it in its status file.
    func launchAtLogin(_ entry: Entry) -> Bool {
        pendingLogin[entry.id] ?? ((entry.status?.launchAtLogin ?? false) || (entry.status?.needsApproval ?? false))
    }

    func install(_ entry: Entry) {
        perform(entry, label: entry.phase == .updateAvailable ? "Atualizando…" : "Instalando…") {
            let url = try await ToolInstaller.install(entry.tool)
            self.refresh()
            try await RunningTool.open(url)
        }
    }

    var pending: [Entry] { entries.filter { $0.phase != .installed } }

    func installPending() {
        pending.forEach(install)
    }

    func remove(_ entry: Entry) {
        guard let copy = entry.installed else { return }
        perform(entry, label: "Removendo…") {
            try await ToolInstaller.remove(copy, launchAtLogin: entry.status?.launchAtLogin ?? false)
        }
    }

    func open(_ entry: Entry) {
        guard let copy = entry.installed else { return }
        perform(entry, label: "Abrindo…") { try await RunningTool.open(copy.url) }
    }

    func configure(_ entry: Entry) {
        guard let copy = entry.installed else { return }
        perform(entry, label: "Abrindo…") { try await RunningTool.send(.openSetup, bundleID: copy.bundleID, appURL: copy.url) }
    }

    func setLaunchAtLogin(_ enabled: Bool, for entry: Entry) {
        guard let copy = entry.installed else { return }
        pendingLogin[entry.id] = enabled
        errors[entry.id] = nil
        Task {
            do {
                try await RunningTool.send(enabled ? .launchAtLoginOn : .launchAtLoginOff, bundleID: copy.bundleID, appURL: copy.url)
            } catch {
                errors[entry.id] = "Não foi possível abrir \(copy.name): \(error.localizedDescription)"
                pendingLogin[entry.id] = nil
            }
            try? await Task.sleep(for: .seconds(8))
            if pendingLogin[entry.id] == enabled { pendingLogin[entry.id] = nil }
        }
    }

    private func perform(_ entry: Entry, label: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard busy[entry.id] == nil else { return }
        busy[entry.id] = label
        errors[entry.id] = nil
        Task {
            do { try await work() } catch { errors[entry.id] = error.localizedDescription }
            busy[entry.id] = nil
            refresh()
        }
    }
}
