import CunhaKit
import Foundation
import SystemConfiguration

// pairing.json: the shared 32-byte key plus what each side knows about the other.
struct Pairing: Codable, Equatable {
    var key: String
    var macID: String
    var phoneID: String? = nil
    var phoneName: String? = nil
    var phoneHost: String? = nil
    var phonePort: Int? = nil
    var pairedAt: Date

    enum CodingKeys: String, CodingKey {
        case key, macID = "macId", phoneID = "phoneId", phoneName, phoneHost, phonePort, pairedAt
    }

    var keyData: Data? { Base64URL.decode(key).flatMap { $0.count == 32 ? $0 : nil } }
    var isComplete: Bool { keyData != nil && phoneID != nil }
    var displayName: String { phoneName ?? "celular" }
}

enum PairingStore {
    static var url: URL {
        SuitePaths.support.appendingPathComponent("pair-file-sharing", isDirectory: true).appendingPathComponent("pairing.json")
    }

    static func load(from url: URL = url) -> Pairing? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Pairing.self, from: data)
    }

    // Written to a 0600 temp file, then renamed, so the key is never readable by others even for a moment.
    static func save(_ pairing: Pairing, to url: URL = url) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(pairing)
        let temp = folder.appendingPathComponent(".pairing-\(getpid()).json")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw TransferError("não foi possível gravar o pareamento")
        }
        guard rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw TransferError("não foi possível gravar o pareamento")
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum MacIdentity {
    private static let idKey = "macID"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: idKey) { return existing }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: idKey)
        return created
    }

    static var name: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }
}

// cunhatools://pair?k=<key>&n=<Mac name>&id=<Mac id>&h=<host>&p=<port>, read by the phone's camera.
struct PairingLink {
    let key: Data
    let macID: String
    let macName: String
    let host: String?
    let port: UInt16

    var url: URL {
        var components = URLComponents()
        components.scheme = "cunhatools"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "k", value: Base64URL.encode(key)),
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "id", value: macID),
            URLQueryItem(name: "h", value: host ?? ""),
            URLQueryItem(name: "p", value: String(port)),
        ]
        // Android's Uri.getQueryParameter reads '+' as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
