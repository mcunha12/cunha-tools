import Foundation

public enum SuitePaths {
    public static let suiteBundleID = "com.marcelocunha.cunhatools"

    public static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cunha Tools", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var status: URL {
        let url = support.appendingPathComponent("status", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
