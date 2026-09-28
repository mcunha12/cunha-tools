import Foundation

// Install → detect version → update → remove, against CUNHA_INSTALL_DIR with a fake tool that is never opened.
@MainActor
enum InstallSelfTest {
    static func run(_ checker: Checker) async {
        guard let installDir = InstallLocation.override?.standardizedFileURL else {
            return checker.fail("defina CUNHA_INSTALL_DIR com uma pasta de teste")
        }
        let protected = [InstallLocation.systemApplications, InstallLocation.userApplications].map(\.standardizedFileURL.path)
        guard !protected.contains(installDir.path) else { return checker.fail("CUNHA_INSTALL_DIR não pode ser uma pasta Aplicativos real") }
        checker.check(InstallLocation.candidates.map(\.standardizedFileURL) == [installDir] && InstallLocation.defaultDirectory.standardizedFileURL == installDir, "CUNHA_INSTALL_DIR substitui /Applications")

        checkVersions(checker)
        listEmbedded()

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cunha-selftest-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try await cycle(checker, installDir: installDir, work: work)
        } catch {
            checker.fail("erro inesperado: \(error.localizedDescription)")
        }
    }

    private static func cycle(_ checker: Checker, installDir: URL, work: URL) async throws {
        let v1Folder = work.appendingPathComponent("v1", isDirectory: true)
        let v2Folder = work.appendingPathComponent("v2", isDirectory: true)
        FakeTool.quarantine(try FakeTool.make(in: v1Folder, version: "1.0.0", build: "1"))
        _ = try FakeTool.make(in: v2Folder, version: "1.1.0", build: "2")
        let target = installDir.appendingPathComponent(FakeTool.fileName, isDirectory: true)
        try? FileManager.default.removeItem(at: target)

        guard let v1 = ToolCatalog.load(from: v1Folder).first, let v2 = ToolCatalog.load(from: v2Folder).first else {
            return checker.fail("catálogo não leu a tool falsa")
        }
        checker.check(v1.bundleID == FakeTool.bundleID && v1.summary == "Tool falsa do autoteste." && v1.symbol == "testtube.2", "catálogo lê CFBundleIdentifier, CunhaToolSummary e CunhaToolSymbol")
        checker.check(v1.requirements == [.audioCapture, .localNetwork], "catálogo lê CunhaToolRequirements e ignora valor desconhecido")

        let model = ToolsModel(tools: [v1])
        checker.check(model.entries.first?.phase == .notInstalled, "estado inicial: não instalada")

        let installed = try await ToolInstaller.install(v1)
        checker.check(installed.standardizedFileURL == target.standardizedFileURL, "instala em CUNHA_INSTALL_DIR")
        checker.check(InstallLocation.installedCopy(of: v1)?.version.short == "1.0.0", "detecta versão instalada 1.0.0")
        checker.check(ToolInstaller.hasQuarantine(v1.url) && !ToolInstaller.hasQuarantine(installed), "remove a quarentena da cópia instalada")
        checker.check(!RunningTool.isRunning(FakeTool.bundleID), "não abre a tool instalada")
        model.refresh()
        checker.check(model.entries.first?.phase == .installed, "estado: instalada")

        let updateModel = ToolsModel(tools: [v2])
        checker.check(updateModel.entries.first?.phase == .updateAvailable, "detecta atualização 1.0.0 → 1.1.0")
        _ = try await ToolInstaller.install(v2)
        updateModel.refresh()
        checker.check(updateModel.entries.first?.installed?.version.short == "1.1.0" && updateModel.entries.first?.phase == .installed, "atualiza para 1.1.0")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: installDir.path))?.filter { $0.hasSuffix(".cunha-new") } ?? []
        checker.check(leftovers.isEmpty, "atualização não deixa pasta temporária")

        guard let copy = updateModel.entries.first?.installed else { return checker.fail("cópia instalada sumiu antes de remover") }
        let trashed = try await ToolInstaller.remove(copy, launchAtLogin: false)
        checker.check(!FileManager.default.fileExists(atPath: target.path), "remove: sai da pasta de instalação")
        checker.check(trashed.map { FileManager.default.fileExists(atPath: $0.path) } == true, "remove: vai para o Lixo (\(trashed?.abbreviatedPath ?? "-"))")
        if let trashed { try? FileManager.default.removeItem(at: trashed) }
        updateModel.refresh()
        checker.check(updateModel.entries.first?.phase == .notInstalled, "estado final: não instalada")
    }

    private static func checkVersions(_ checker: Checker) {
        let v = { BundleVersion(short: $0, build: $1) }
        checker.check(v("0.9.0", "9") < v("0.10.0", "1"), "versão: 0.10.0 > 0.9.0")
        checker.check(v("1.0", "1") == v("1.0.0", "1"), "versão: 1.0 == 1.0.0")
        checker.check(v("1.0.0", "2") < v("1.0.0", "3"), "versão: mesmo número, build maior vence")
        checker.check(!(v("0.3.0", "3") < v("0.2.0", "9")), "versão: instalada mais nova não vira atualização")
    }

    private static func listEmbedded() {
        let tools = ToolCatalog.load()
        SelfTest.log("tools embutidas em \(ToolCatalog.embeddedDirectory.path): \(tools.count)")
        for tool in tools {
            let requirements = tool.requirements.map(\.rawValue).joined(separator: ",")
            SelfTest.log("  \(tool.name) \(tool.bundleID) \(tool.version) (\(tool.version.build)) requisitos=[\(requirements)] símbolo=\(tool.symbol ?? "-") ícone=\(tool.iconURL?.lastPathComponent ?? "-")")
        }
    }
}
