import Foundation

// A minimal unsigned bundle for the self-tests; it is never opened.
enum FakeTool {
    static let bundleID = "com.marcelocunha.cunhatools.selftest"
    static let fileName = "Cunha Selftest.app"

    static func make(in folder: URL, version: String, build: String, bundleID: String = Self.bundleID) throws -> URL {
        let app = folder.appendingPathComponent(fileName, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let files = FileManager.default
        try? files.removeItem(at: app)
        try files.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try files.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleName": "Cunha Selftest",
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "CunhaSelftest",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CunhaToolSummary": "Tool falsa do autoteste.",
            "CunhaToolRequirements": ["audioCapture", "phone", "desconhecido"],
            "CunhaToolSymbol": "testtube.2",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/CunhaSelftest")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return app
    }

    static func quarantine(_ url: URL) {
        let value = "0083;00000000;Cunha Tools selftest;"
        _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }
}
