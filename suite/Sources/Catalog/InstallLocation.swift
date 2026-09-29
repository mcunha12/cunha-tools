import Foundation

// Where tools are installed: CUNHA_INSTALL_DIR for tests, else /Applications, falling back to ~/Applications.
enum InstallLocation {
    static let overrideKey = "CUNHA_INSTALL_DIR"

    static var override: URL? {
        ProcessInfo.processInfo.environment[overrideKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var systemApplications: URL { URL(fileURLWithPath: "/Applications", isDirectory: true) }
    static var userApplications: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true) }

    static var candidates: [URL] {
        override.map { [$0] } ?? [systemApplications, userApplications]
    }

    static var defaultDirectory: URL {
        if let override { return override }
        return FileManager.default.isWritableFile(atPath: systemApplications.path) ? systemApplications : userApplications
    }

    static func installedCopy(of tool: ToolBundle) -> ToolBundle? {
        for directory in candidates {
            let url = directory.appendingPathComponent(tool.url.lastPathComponent, isDirectory: true)
            if let copy = ToolBundle(url: url), copy.bundleID == tool.bundleID { return copy }
        }
        return nil
    }

    // Copies of the bundle in the install folders under any file name, except the one kept.
    static func otherCopies(of bundleID: String, keeping kept: URL) -> [URL] {
        return candidates.flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter {
                $0.pathExtension == "app" && $0.realPath != kept.realPath && ToolBundle(url: $0)?.bundleID == bundleID
            }
        }
    }

    // An update replaces the copy where it already is; a first install goes to the default folder.
    static func destination(for tool: ToolBundle) -> URL {
        installedCopy(of: tool)?.url ?? defaultDirectory.appendingPathComponent(tool.url.lastPathComponent, isDirectory: true)
    }
}
