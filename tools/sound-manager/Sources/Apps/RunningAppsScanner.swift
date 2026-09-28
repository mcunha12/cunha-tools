import AppKit
import CoreAudio

struct AppItem: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleID: String?
    let pids: [pid_t]
    let audioProcessIDs: Set<AudioObjectID>
    let isPlaying: Bool

    var icon: NSImage {
        AppIconCache.icon(for: pids.first ?? 0)
    }
}

enum AppIconCache {
    private static var icons: [pid_t: NSImage] = [:]

    static func icon(for pid: pid_t) -> NSImage {
        if let icon = icons[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(for: .application)
        icon.size = NSSize(width: 32, height: 32)
        icons[pid] = icon
        return icon
    }
}

enum RunningAppsScanner {
    static func scan() -> [AppItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != ownPID && !$0.isTerminated }
        let appsByPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var audioByPID: [pid_t: [AudioProcess]] = [:]
        for process in AudioProcess.all() {
            guard let owner = owningApp(of: process, in: appsByPID, running: running) else { continue }
            audioByPID[owner.processIdentifier, default: []].append(process)
        }

        var groups: [String: [NSRunningApplication]] = [:]
        for app in running {
            let hasAudio = audioByPID[app.processIdentifier] != nil
            guard app.activationPolicy == .regular || hasAudio else { continue }
            groups[groupKey(app), default: []].append(app)
        }

        return groups.map { key, apps in
            let audio = apps.flatMap { audioByPID[$0.processIdentifier] ?? [] }
            return AppItem(
                id: key,
                name: displayName(apps.first),
                bundleID: apps.first?.bundleIdentifier,
                pids: apps.map(\.processIdentifier),
                audioProcessIDs: Set(audio.map(\.objectID)),
                isPlaying: audio.contains { $0.isPlaying }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func displayName(_ app: NSRunningApplication?) -> String {
        let name = app?.localizedName ?? app?.bundleIdentifier ?? "App"
        return name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}\u{200F}")))
    }

    private static func groupKey(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? "pid-\(app.processIdentifier)"
    }

    private static func owningApp(of process: AudioProcess, in appsByPID: [pid_t: NSRunningApplication], running: [NSRunningApplication]) -> NSRunningApplication? {
        if let app = appsByPID[process.pid], app.activationPolicy == .regular { return app }
        var current = process.pid
        for _ in 0..<4 {
            guard let parent = ProcessLineage.parentPID(of: current) else { break }
            if let app = appsByPID[parent] { return app }
            current = parent
        }
        if let responsible = ProcessLineage.responsiblePID(of: process.pid), let app = appsByPID[responsible] { return app }
        if let bundleID = process.bundleID,
           let app = running.first(where: { app in app.bundleIdentifier.map { bundleID.hasPrefix($0 + ".") } ?? false }) {
            return app
        }
        return appsByPID[process.pid]
    }
}
