import Foundation

enum CommitComparison: String {
    case identical, ahead, behind, diverged
}

// GitHub REST without a token: 60 requests per hour per IP, enough for a manual button.
struct UpdateSource: Sendable {
    let repository: String
    let branch: String

    static let branchOverrideKey = "CUNHA_UPDATE_BRANCH"

    static var configured: UpdateSource? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let repository = info["CunhaUpdateRepository"] as? String, !repository.isEmpty else { return nil }
        let branch = ProcessInfo.processInfo.environment[branchOverrideKey] ?? info["CunhaUpdateBranch"] as? String ?? "main"
        return UpdateSource(repository: repository, branch: branch)
    }

    func latestCommit() async throws -> String {
        guard let sha = try await object(path: "commits/\(branch)")?["sha"] as? String else {
            throw InstallError(message: "O GitHub não devolveu o último commit de \(branch).")
        }
        return sha
    }

    // nil when GitHub does not know the installed commit, as in a local build that was never pushed.
    func comparison(from installed: String, to latest: String) async throws -> CommitComparison? {
        guard let json = try await object(path: "compare/\(installed)...\(latest)", allowMissing: true) else { return nil }
        return (json["status"] as? String).flatMap(CommitComparison.init(rawValue:))
    }

    func downloadSource(of commit: String, to file: URL) async throws {
        let temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await URLSession.shared.download(for: request(path: "tarball/\(commit)"))
        } catch {
            throw InstallError(message: "Sem conexão com o GitHub: \(error.localizedDescription)")
        }
        try check(response)
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
