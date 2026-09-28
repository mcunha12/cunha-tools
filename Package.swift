// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

func hasSwiftFiles(_ path: String) -> Bool {
    let enumerator = FileManager.default.enumerator(atPath: "\(root)/\(path)")
    while let file = enumerator?.nextObject() as? String {
        if file.hasSuffix(".swift") { return true }
    }
    return false
}

// Each app: SwiftPM executable name and folder. Checks run as --selftest flags inside each binary.
let apps: [(name: String, path: String)] = [
    ("CunhaTools", "suite"),
    ("SoundManager", "tools/sound-manager"),
]

var targets: [Target] = [
    .target(name: "CunhaKit", path: "shared/CunhaKit", swiftSettings: settings),
]
// CUNHA_ONLY=tools/sound-manager,suite limits the package to those folders, so a broken tool does not block another tool's build.
let only = ProcessInfo.processInfo.environment["CUNHA_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
for app in apps where hasSwiftFiles("\(app.path)/Sources") && (only?.contains(app.path) ?? true) {
    targets.append(.executableTarget(name: app.name, dependencies: ["CunhaKit"], path: "\(app.path)/Sources", swiftSettings: settings))
}

let package = Package(
    name: "CunhaTools",
    platforms: [.macOS(.v15)],
    targets: targets
)
