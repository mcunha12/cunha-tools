import AppKit

@MainActor
final class SuiteUpdater: ObservableObject {
    enum Decision: Equatable { case upToDate, update(version: String, dmg: URL) }
    enum Phase: Equatable { case idle, checking, upToDate, downloading(String), installing, failed(String) }

    @Published private(set) var phase: Phase = .idle
    let source = UpdateSource.configured

    static var installedCommit: String? { Bundle.main.infoDictionary?["CunhaSourceCommit"] as? String }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        case .idle, .upToDate, .failed: false
        }
    }

    // --render-ui --update <fase> shows a phase without calling GitHub.
    func showPreview(_ phase: Phase) { self.phase = phase }

    // One click checks and, when GitHub has a newer release, downloads its DMG and installs it without asking again.
    func checkAndUpdate() {
        guard let source, !isBusy else { return }
        Task {
            do {
                phase = .checking
                let release = try await source.latestRelease()
                guard case let .update(version, dmg) = try Self.decide(release, installed: Bundle.main.shortVersion) else {
                    phase = .upToDate
                    return
                }
                phase = .downloading(version)
                let destination = Self.suiteDestination
                try await Self.update(from: dmg, version: version, source: source, at: destination) { self.phase = .installing }
                await Self.trashPreviousSuites(keeping: destination)
                Self.relaunch(destination)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // A release that is not newer never replaces the running suite, with or without a DMG.
    static func decide(_ release: Release, installed: String) throws -> Decision {
        guard BundleVersion.compare(release.version, installed) == .orderedDescending else { return .upToDate }
        guard let dmg = release.dmg else {
            throw InstallError(message: "A versão \(release.version) do GitHub não tem o \(UpdateSource.assetName).")
        }
        return .update(version: release.version, dmg: dmg)
    }

    // Installs the suite from the DMG, then the outdated tools; the download is gone afterwards, also on failure.
    static func update(from dmg: URL, version: String, source: UpdateSource, at destination: URL, onInstall: () -> Void) async throws {
        defer { UpdateImage.cleanUp() }
        try FileManager.default.createDirectory(at: UpdateImage.workFolder, withIntermediateDirectories: true)
        try await source.download(dmg, to: UpdateImage.downloadFile)
        onInstall()
        try await install(UpdateImage.downloadFile, version: version, at: destination)
        try await updateInstalledTools(from: destination)
    }

    // The DMG is detached before this returns, also when the check or the copy fails.
    private static func install(_ dmg: URL, version: String, at destination: URL) async throws {
        let mount = try await UpdateImage.attach(dmg)
        do {
            try await replaceSuite(at: destination, with: try await UpdateImage.suite(in: mount, version: version))
        } catch {
            await UpdateImage.detach(mount)
            throw error
        }
        await UpdateImage.detach(mount)
    }

    // Only tools already installed and older than the ones in the new suite are replaced; the open ones reopen.
    private static func updateInstalledTools(from suite: URL) async throws {
        for tool in ToolCatalog.load(from: suite.appendingPathComponent("Contents/Library/Tools", isDirectory: true)) {
            guard let installed = InstallLocation.installedCopy(of: tool), installed.version < tool.version else { continue }
            let wasRunning = RunningTool.isRunning(tool.bundleID)
            let url = try await ToolInstaller.install(tool)
            if wasRunning { try? await RunningTool.open(url) }
        }
    }

    private static func replaceSuite(at destination: URL, with suite: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try ToolInstaller.replace(destination, with: suite)
            ToolInstaller.removeQuarantine(destination)
        }.value
    }

    // Always the install folder, wherever the running copy is: build/, Downloads or a DMG.
    static var suiteDestination: URL {
        let current = Bundle.main.bundleURL
        guard let suite = ToolBundle(url: current) else { return InstallLocation.defaultDirectory.appendingPathComponent(current.lastPathComponent, isDirectory: true) }
        return InstallLocation.destination(for: suite)
    }

    // Other copies in the install folders and the running copy go to the Trash; a DMG or App Translocation copy stays.
    static func trashPreviousSuites(keeping destination: URL) async {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        var copies = InstallLocation.otherCopies(of: bundleID, keeping: destination)
        let current = Bundle.main.bundleURL
        if current.realPath != destination.realPath, !current.path.contains("/AppTranslocation/"), !copies.map(\.realPath).contains(current.realPath) {
            copies.append(current)
        }
        await ToolInstaller.trash(copies)
    }

    // A detached shell waits for this process to exit, then opens the new copy.
    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
