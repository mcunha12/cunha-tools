import AppKit

@MainActor
final class SuiteUpdater: ObservableObject {
    enum Decision: Equatable { case upToDate, update(String) }
    enum Phase: Equatable { case idle, checking, upToDate, downloading, building, installing, failed(String) }

    @Published private(set) var phase: Phase = .idle
    let source = UpdateSource.configured

    static var installedCommit: String? { Bundle.main.infoDictionary?["CunhaSourceCommit"] as? String }

    var isBusy: Bool { [.checking, .downloading, .building, .installing].contains(phase) }

    // One click checks and, when the branch has a newer commit, downloads, builds and installs it without asking again.
    func checkAndUpdate() {
        guard let source, !isBusy else { return }
        Task {
            do {
                phase = .checking
                let latest = try await source.latestCommit()
                guard try await Self.decide(installed: Self.installedCommit, latest: latest, source: source) != .upToDate else {
                    phase = .upToDate
                    return
                }
                guard await UpdateBuilder.hasToolchain() else {
                    throw InstallError(message: "A atualização compila o código e exige o Command Line Tools. No Terminal, rode xcode-select --install.")
                }
                phase = .downloading
                let suite = try await Self.fetchAndBuild(latest, from: source) { self.phase = .building }
                phase = .installing
                try await Self.updateInstalledTools(from: suite)
                let destination = Self.suiteDestination
                try await Self.replaceSuite(at: destination, with: suite)
                await Self.trashPreviousSuites(keeping: destination)
                UpdateBuilder.cleanUp()
                Self.relaunch(destination)
            } catch {
                UpdateBuilder.cleanUp()
                phase = .failed(error.localizedDescription)
            }
        }
    }

    static func decide(installed: String?, latest: String, source: UpdateSource) async throws -> Decision {
        guard let installed, !installed.isEmpty else { return .update(latest) }
        if installed == latest { return .upToDate }
        switch try await source.comparison(from: installed, to: latest) {
        case .identical?, .behind?: return .upToDate
        case .ahead?, .diverged?, nil: return .update(latest)
        }
    }

    static func fetchAndBuild(_ commit: String, from source: UpdateSource, onBuild: @MainActor () -> Void) async throws -> URL {
        let folder = UpdateBuilder.workFolder.appendingPathComponent(commit, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("source.tar.gz")
        try await source.downloadSource(of: commit, to: archive)
        let root = try await UpdateBuilder.extract(archive, into: folder.appendingPathComponent("source", isDirectory: true))
        onBuild()
        return try await UpdateBuilder.build(source: root, commit: commit)
    }

    // Only tools already installed and older than the new build are replaced; the open ones reopen.
    static func updateInstalledTools(from suite: URL) async throws {
        for tool in ToolCatalog.load(from: suite.appendingPathComponent("Contents/Library/Tools", isDirectory: true)) {
            guard let installed = InstallLocation.installedCopy(of: tool), installed.version < tool.version else { continue }
            let wasRunning = RunningTool.isRunning(tool.bundleID)
            let url = try await ToolInstaller.install(tool)
            if wasRunning { try? await RunningTool.open(url) }
        }
    }

    static func replaceSuite(at destination: URL, with suite: URL) async throws {
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
