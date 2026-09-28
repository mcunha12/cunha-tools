import AppKit

enum ExtensionInstaller {
    static var installedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sound Manager/BrowserExtension", isDirectory: true)
    }

    static func install(for app: AppItem) {
        do {
            try copyExtension()
        } catch {
            NSLog("SoundManager: extensão não copiada: \(error.localizedDescription)")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installedURL.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([installedURL])
        openExtensionsPage(in: app)
    }

    private static func copyExtension() throws {
        guard let bundled = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: installedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: installedURL.path) {
            try manager.removeItem(at: installedURL)
        }
        try manager.copyItem(at: bundled, to: installedURL)
    }

    private static func openExtensionsPage(in app: AppItem) {
        guard let pid = app.pids.first,
              let appURL = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              let page = URL(string: "chrome://extensions") else { return }
        NSWorkspace.shared.open([page], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}
