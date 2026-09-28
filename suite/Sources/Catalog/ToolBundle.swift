import Foundation

enum ToolRequirement: String, CaseIterable, Sendable {
    case audioCapture
    case localNetwork

    var title: String {
        switch self {
        case .audioCapture: "Gravação de áudio do sistema"
        case .localNetwork: "Rede local"
        }
    }
}

struct BundleVersion: Comparable, Sendable, CustomStringConvertible {
    let short: String
    let build: String

    var description: String { short }

    static func < (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
        let order = compare(lhs.short, rhs.short)
        return order == .orderedSame ? compare(lhs.build, rhs.build) == .orderedAscending : order == .orderedAscending
    }

    static func == (lhs: BundleVersion, rhs: BundleVersion) -> Bool {
        compare(lhs.short, rhs.short) == .orderedSame && compare(lhs.build, rhs.build) == .orderedSame
    }

    // Numeric per component, missing components count as zero: 0.10 > 0.9 and 1.0 == 1.0.0.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

// A tool .app read straight from its Info.plist, embedded in the suite or installed.
struct ToolBundle: Identifiable, Sendable {
    let url: URL
    let name: String
    let bundleID: String
    let version: BundleVersion
    let summary: String?
    let requirements: [ToolRequirement]
    let symbol: String?
    let iconURL: URL?

    var id: String { bundleID }

    init?(url: URL) {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String else { return nil }
        self.url = url
        self.bundleID = bundleID
        name = info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
        version = BundleVersion(short: info["CFBundleShortVersionString"] as? String ?? "0", build: info["CFBundleVersion"] as? String ?? "0")
        summary = info["CunhaToolSummary"] as? String
        requirements = (info["CunhaToolRequirements"] as? [String] ?? []).compactMap(ToolRequirement.init(rawValue:))
        symbol = info["CunhaToolSymbol"] as? String
        iconURL = Self.iconURL(bundle: url, iconFile: info["CFBundleIconFile"] as? String)
    }

    private static func iconURL(bundle: URL, iconFile: String?) -> URL? {
        guard let iconFile, !iconFile.isEmpty else { return nil }
        let file = iconFile.hasSuffix(".icns") ? iconFile : iconFile + ".icns"
        let url = bundle.appendingPathComponent("Contents/Resources/\(file)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum ToolCatalog {
    static var embeddedDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/Tools", isDirectory: true)
    }

    static func load(from directory: URL = embeddedDirectory) -> [ToolBundle] {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "app" }
            .compactMap(ToolBundle.init(url:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
