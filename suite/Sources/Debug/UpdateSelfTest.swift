import Foundation

// --selftest-update: real GitHub and a real build of CUNHA_UPDATE_BRANCH (or main), installed into CUNHA_INSTALL_DIR. Takes up to 5 minutes.
@MainActor
enum UpdateSelfTest {
    private static let rootCommit = "d8538955a8bc4b2e88181fe1fd0ec6cf2da064ab"

    static func run(_ checker: Checker) async {
        guard let installDir = InstallLocation.override else { return checker.fail("CUNHA_INSTALL_DIR definido") }
        guard let source = UpdateSource.configured else { return checker.fail("CunhaUpdateRepository no Info.plist") }
        do {
            let latest = try await source.latestCommit()
            checker.check(latest.count == 40, "GitHub devolve o commit mais novo de \(source.branch): \(latest.prefix(7))")
            checker.check(try await SuiteUpdater.decide(installed: latest, latest: latest, source: source) == .upToDate, "mesmo commit: atualizado, sem download")
            checker.check(try await SuiteUpdater.decide(installed: rootCommit, latest: latest, source: source) == .update(latest), "commit antigo: atualiza")
            checker.check(try await SuiteUpdater.decide(installed: latest, latest: rootCommit, source: source) == .upToDate, "build à frente do branch: não volta de versão")
            checker.check(try await SuiteUpdater.decide(installed: String(repeating: "0", count: 40), latest: latest, source: source) == .update(latest), "commit que o GitHub não conhece: atualiza")
            checker.check(try await SuiteUpdater.decide(installed: nil, latest: latest, source: source) == .update(latest), "build sem commit gravado: atualiza")
            checker.check(await UpdateBuilder.hasToolchain(), "Command Line Tools presente")

            let started = Date()
            let suite = try await SuiteUpdater.fetchAndBuild(latest, from: source) {}
            SelfTest.log(String(format: "download e build em %.0f s", Date().timeIntervalSince(started)))
            let built = NSDictionary(contentsOf: suite.appendingPathComponent("Contents/Info.plist"))
            checker.check(built?["CunhaSourceCommit"] as? String == latest, "build grava o commit no Info.plist")
            checker.check(await UpdateBuilder.isValidlySigned(suite), "suíte nova com assinatura válida")
            checker.check(!ToolCatalog.load(from: suite.appendingPathComponent("Contents/Library/Tools")).isEmpty, "suíte nova traz as tools embutidas")

            let destination = installDir.appendingPathComponent("Cunha Tools.app", isDirectory: true)
            try? FileManager.default.removeItem(at: destination)
            _ = try FakeTool.make(in: installDir, version: "0.0.1", build: "1")
            try FileManager.default.moveItem(at: installDir.appendingPathComponent(FakeTool.fileName), to: destination)
            try await SuiteUpdater.replaceSuite(at: destination, with: suite)
            let replaced = NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
            checker.check(replaced?["CunhaSourceCommit"] as? String == latest, "troca a suíte no lugar da cópia antiga")
            checker.check(!ToolInstaller.hasQuarantine(destination), "suíte trocada sem quarentena")

            UpdateBuilder.cleanUp()
            checker.check(!FileManager.default.fileExists(atPath: UpdateBuilder.workFolder.path), "limpa o código baixado e o build")
            try? FileManager.default.removeItem(at: destination)
        } catch {
            checker.fail("erro: \(error.localizedDescription)")
        }
    }
}
