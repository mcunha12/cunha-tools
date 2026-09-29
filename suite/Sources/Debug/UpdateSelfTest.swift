import CunhaKit
import Foundation

// --selftest-update: the release check against the real GitHub, then CUNHA_UPDATE_DMG (from make-dmg.sh or release.sh) and broken DMGs through the real update into CUNHA_INSTALL_DIR.
@MainActor
enum UpdateSelfTest {
    static let dmgKey = "CUNHA_UPDATE_DMG"
    private static let releaseWithoutDMG = "apple/swift-argument-parser"

    static func run(_ checker: Checker) async {
        guard let installDir = InstallLocation.override?.standardizedFileURL else {
            return checker.fail("defina CUNHA_INSTALL_DIR com uma pasta de teste")
        }
        let protected = [InstallLocation.systemApplications, InstallLocation.userApplications].map(\.standardizedFileURL.path)
        guard !protected.contains(installDir.path) else { return checker.fail("CUNHA_INSTALL_DIR não pode ser uma pasta Aplicativos real") }
        guard let path = ProcessInfo.processInfo.environment[dmgKey], FileManager.default.fileExists(atPath: path) else {
            return checker.fail("defina \(dmgKey) com um DMG do make-dmg.sh ou do release.sh")
        }
        guard let source = UpdateSource.configured else { return checker.fail("CunhaUpdateRepository no Info.plist") }

        await checkGitHub(checker, source: source)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cunha-selftest-update-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try await checkInstall(checker, dmg: URL(fileURLWithPath: path), source: source, installDir: installDir, work: work)
        } catch {
            checker.fail("erro inesperado: \(error.localizedDescription)")
        }
    }

    private static func checkGitHub(_ checker: Checker, source: UpdateSource) async {
        let installed = Bundle.main.shortVersion
        do {
            let release = try await source.latestRelease()
            let decision = try SuiteUpdater.decide(release, installed: installed)
            checker.check(release.dmg?.lastPathComponent == UpdateSource.assetName, "\(source.repository): versão \(release.version) com o \(UpdateSource.assetName); instalada \(installed): \(decision == .upToDate ? "atualizado" : "atualiza")")
        } catch {
            checker.check(error.localizedDescription == UpdateSource.noReleaseMessage, "\(source.repository) sem versão publicada: \(error.localizedDescription)")
        }

        do {
            let release = try await UpdateSource(repository: releaseWithoutDMG).latestRelease()
            checker.check(try SuiteUpdater.decide(release, installed: "999") == .upToDate, "versão \(release.version) de \(releaseWithoutDMG) abaixo da instalada: atualizado, sem pedir o DMG")
            do {
                _ = try SuiteUpdater.decide(release, installed: installed)
                checker.fail("versão \(release.version) sem o DMG acima da instalada: devia falhar")
            } catch {
                checker.check(error.localizedDescription.hasSuffix("não tem o \(UpdateSource.assetName)."), "versão sem o DMG acima da instalada: \(error.localizedDescription)")
            }
        } catch {
            checker.fail("\(releaseWithoutDMG): \(error.localizedDescription)")
        }
    }

    private static func checkInstall(_ checker: Checker, dmg: URL, source: UpdateSource, installDir: URL, work: URL) async throws {
        let version = Bundle.main.shortVersion
        let destination = SuiteUpdater.suiteDestination
        guard destination.deletingLastPathComponent().standardizedFileURL == installDir else {
            return checker.fail("a suíte iria para \(destination.path), fora de CUNHA_INSTALL_DIR")
        }
        try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: try FakeTool.make(in: work, version: "0.0.1", build: "1"), to: destination)

        for bad in try await brokenImages(in: work, real: dmg, version: version) {
            do {
                try await SuiteUpdater.update(from: bad.dmg, version: bad.version, source: source, at: destination) {}
                checker.fail("\(bad.label): devia recusar")
            } catch {
                let untouched = ToolBundle(url: destination)?.bundleID == FakeTool.bundleID
                let clean = await noMountLeft() && !FileManager.default.fileExists(atPath: UpdateImage.workFolder.path)
                checker.check(untouched && clean, "\(bad.label): recusa, cópia antiga intacta, sem mount, cache apagado — \(error.localizedDescription)")
            }
        }

        let started = Date()
        try await SuiteUpdater.update(from: dmg, version: version, source: source, at: destination) {}
        SelfTest.log(String(format: "download, verificação e troca em %.1f s", Date().timeIntervalSince(started)))
        let installed = ToolBundle(url: destination)
        checker.check(installed?.bundleID == Bundle.main.bundleIdentifier && installed?.version.short == version, "troca a cópia antiga pela suíte \(version) do DMG")
        checker.check(await UpdateImage.isValidlySigned(destination), "suíte instalada com assinatura válida")
        checker.check(!ToolInstaller.hasQuarantine(destination), "suíte instalada sem quarentena")
        checker.check(!ToolCatalog.load(from: destination.appendingPathComponent("Contents/Library/Tools")).isEmpty, "suíte instalada traz as tools embutidas")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: installDir.path))?.filter { $0.hasSuffix(".cunha-new") } ?? []
        checker.check(leftovers.isEmpty, "troca não deixa pasta temporária")
        checker.check(await noMountLeft(), "DMG desmontado depois da troca (hdiutil info)")
        checker.check(!FileManager.default.fileExists(atPath: UpdateImage.workFolder.path), "cache do download apagado")
        try? FileManager.default.removeItem(at: destination)
    }

    // Each one must be refused: the release version it announces goes with it.
    private static func brokenImages(in work: URL, real: URL, version: String) async throws -> [(label: String, dmg: URL, version: String)] {
        let garbage = work.appendingPathComponent("lixo.dmg")
        try Data("não é um DMG".utf8).write(to: garbage)
        let otherID = try await image("outro-id", in: work) { try FakeTool.make(in: $0, version: version, build: "1") }
        let unsigned = try await image("sem-assinatura", in: work) { try FakeTool.make(in: $0, version: version, build: "1", bundleID: Bundle.main.bundleIdentifier ?? "") }
        return [
            ("download falha", work.appendingPathComponent("inexistente.dmg"), version),
            ("DMG que não monta", garbage, version),
            ("DMG sem o \(UpdateImage.appName)", try await image("vazio", in: work) { _ in nil }, version),
            ("DMG com outro bundle ID", otherID, version),
            ("DMG sem assinatura", unsigned, version),
            ("DMG de outra versão", real, "0.0.1"),
        ]
    }

    // A read-only DMG whose app, when the closure makes one, is named Cunha Tools.app.
    private static func image(_ name: String, in work: URL, app: (URL) throws -> URL?) async throws -> URL {
        let folder = work.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let made = try app(folder) {
            try FileManager.default.moveItem(at: made, to: folder.appendingPathComponent(UpdateImage.appName, isDirectory: true))
        }
        let dmg = work.appendingPathComponent("\(name).dmg")
        let result = try await hdiutil(["create", "-volname", name, "-srcfolder", folder.path, "-fs", "HFS+", "-format", "UDRO", "-ov", dmg.path])
        guard result.succeeded else { throw InstallError(message: "hdiutil create \(name): \(result.errorOutput)") }
        return dmg
    }

    private static func noMountLeft() async -> Bool {
        guard let result = try? await hdiutil(["info"]), result.succeeded else { return false }
        return !result.output.contains("cunha-update-")
    }

    private static func hdiutil(_ arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        return try await runProcess(process, timeout: 120)
    }
}
