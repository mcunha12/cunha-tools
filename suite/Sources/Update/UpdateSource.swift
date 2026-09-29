import Foundation

struct Release: Sendable {
    let version: String
    let dmg: URL?
}

// GitHub REST without a token: 60 requests per hour per IP, enough for a manual button.
struct UpdateSource: Sendable {
    let repository: String

    static let assetName = "CunhaTools.dmg"
    static let noReleaseMessage = "O GitHub ainda não tem versão publicada do Cunha Tools."

    static var configured: UpdateSource? {
        guard let repository = Bundle.main.infoDictionary?["CunhaUpdateRepository"] as? String, !repository.isEmpty else { return nil }
        return UpdateSource(repository: repository)
    }

    // GitHub leaves drafts and pre-releases out of releases/latest.
    func latestRelease() async throws -> Release {
        guard let json = try await object(path: "releases/latest", allowMissing: true), let tag = json["tag_name"] as? String else {
            throw InstallError(message: Self.noReleaseMessage)
        }
        let asset = (json["assets"] as? [[String: Any]])?.first { $0["name"] as? String == Self.assetName }
        let dmg = (asset?["browser_download_url"] as? String).flatMap(URL.init(string:))
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, dmg: dmg)
    }

    func download(_ url: URL, to file: URL) async throws {
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 60))
        } catch {
            throw InstallError(message: "O download do \(Self.assetName) parou: \(error.localizedDescription)")
        }
        // The self-test downloads a local DMG through a file URL, which has no HTTP status.
        if response is HTTPURLResponse { try check(response) }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temporary, to: file)
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/\(path)")!, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cunha-Tools", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func object(path: String, allowMissing: Bool = false) async throws -> [String: Any]? {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request(path: path))
        } catch {
            throw InstallError(message: "Sem conexão com o GitHub: \(error.localizedDescription)")
        }
        if allowMissing, (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try check(response)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw InstallError(message: "Resposta inválida do GitHub.") }
        if [403, 429].contains(http.statusCode), http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
            throw InstallError(message: "Limite de 60 consultas por hora do GitHub atingido. Tente de novo em 1 hora.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw InstallError(message: "O GitHub respondeu \(http.statusCode) em \(http.url?.path ?? "").")
        }
    }
}
