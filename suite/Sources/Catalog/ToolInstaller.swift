import AppKit
import CunhaKit

struct InstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum ToolInstaller {
    // Copies the embedded bundle over the installed one; the caller decides whether to open it.
    static func install(_ tool: ToolBundle) async throws -> URL {
        let destination = InstallLocation.destination(for: tool)
        await RunningTool.quit(bundleID: tool.bundleID)
        let source = tool.url
        try await Task.detached(priority: .userInitiated) {
            try replace(destination, with: source)
            removeQuarantine(destination)
        }.value
        await trash(InstallLocation.otherCopies(of: tool.bundleID, keeping: destination))
        return destination
    }

    // One item per call, so a copy on a read-only volume does not keep the others out of the Trash. Returns the Trash locations.
    @discardableResult
    static func trash(_ copies: [URL]) async -> [URL] {
        var trashed: [URL] = []
        for copy in copies {
            if let location = try? await NSWorkspace.shared.recycle([copy])[copy] { trashed.append(location) }
        }
        return trashed
    }

    // Returns where the bundle landed in the Trash.
    @discardableResult
    static func remove(_ copy: ToolBundle, launchAtLogin: Bool) async throws -> URL? {
        await RunningTool.prepareRemoval(bundleID: copy.bundleID, appURL: copy.url, launchAtLogin: launchAtLogin)
        let trashed: [URL: URL]
        do {
            trashed = try await NSWorkspace.shared.recycle([copy.url])
        } catch {
            throw InstallError(message: friendly(error, action: "remover"))
        }
        try? FileManager.default.removeItem(at: ToolStatus.url(for: copy.bundleID))
        return trashed[copy.url]
    }

    nonisolated static func replace(_ destination: URL, with source: URL) throws {
        let files = FileManager.default
        let folder = destination.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".\(destination.lastPathComponent).cunha-new", isDirectory: true)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try? files.removeItem(at: staging)
            try files.copyItem(at: source, to: staging)
            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try files.moveItem(at: staging, to: destination)
        } catch {
            try? files.removeItem(at: staging)
            throw InstallError(message: friendly(error, action: "instalar em \(folder.path)"))
        }
    }

    nonisolated static func removeQuarantine(_ bundle: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(bundle.path, attribute, XATTR_NOFOLLOW)
        let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)
        while let item = enumerator?.nextObject() as? URL {
            removexattr(item.path, attribute, XATTR_NOFOLLOW)
        }
    }

    nonisolated static func hasQuarantine(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    nonisolated private static func friendly(_ error: Error, action: String) -> String {
        let nsError = error as NSError
        let denied = [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(nsError.code)
            || (nsError.underlyingErrors.first as NSError?).map { $0.code == Int(EPERM) || $0.code == Int(EACCES) } == true
        if denied {
            return "Sem permissão para \(action). Em Ajustes do Sistema → Privacidade e Segurança → Gerenciamento de apps, ative o Cunha Tools."
        }
        return "Não foi possível \(action): \(error.localizedDescription)"
    }
}
