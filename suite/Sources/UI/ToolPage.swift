import AppKit
import SwiftUI

struct ToolPage: View {
    enum Tab: String, CaseIterable, Identifiable {
        case setup = "Configuração"
        case guide = "Guia"

        var id: String { rawValue }
    }

    @EnvironmentObject private var tools: ToolsModel
    let entry: ToolsModel.Entry
    @Binding var page: Page
    @State private var tab: Tab
    @State private var confirmingRemoval = false

    init(entry: ToolsModel.Entry, page: Binding<Page>, opensGuide: Bool = false) {
        self.entry = entry
        _page = page
        _tab = State(initialValue: opensGuide || !(entry.needsSetup || entry.tool.guide.isEmpty) ? .guide : .setup)
    }

    private var tool: ToolBundle { entry.tool }
    private var busy: String? { tools.busy[entry.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: tool.name, subtitle: tool.summary ?? "") {
                StatusPill(text: entry.state.text, symbol: entry.state.symbol, color: entry.state.color, caption: "Versão \(entry.installed?.version ?? tool.version)")
            }
            hero
            Picker("Seção", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch tab {
            case .setup: ToolSetup(entry: entry, page: $page)
            case .guide: ToolGuide(steps: tool.guide, tint: tool.tintColor)
            }
        }
        .confirmationDialog("Remover \(tool.name)?", isPresented: $confirmingRemoval) {
            Button("Mover para o Lixo", role: .destructive) { tools.remove(entry) }
        } message: {
            Text("A tool fecha, deixa de abrir ao iniciar o Mac e vai para o Lixo.")
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 22) {
            ToolIcon(tool: tool, size: 68)
            VStack(alignment: .leading, spacing: 8) {
                Text(headline).font(.system(size: 26, weight: .bold))
                Text(detail).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions.padding(.top, 12)
                if let error = tools.errors[entry.id] { ErrorText(text: error) }
            }
        }
        .card(padding: 28)
    }

    private var folder: String { entry.installed?.url.deletingLastPathComponent().abbreviatedPath ?? InstallLocation.defaultDirectory.abbreviatedPath }

    private var headline: String {
        switch entry.phase {
        case .notInstalled: return "Pronta para instalar."
        case .updateAvailable: return "Versão \(tool.version) disponível."
        case .installed: return entry.isRunning ? "Instalada e aberta." : "Instalada e fechada."
        }
    }

    private var detail: String {
        switch entry.phase {
        case .notInstalled: return "O Cunha Tools copia a tool para \(folder) e abre ao terminar."
        case .updateAvailable: return "Instalada: \(entry.installed?.version.description ?? "?") em \(folder). A atualização fecha a tool, troca a cópia e abre de novo."
        case .installed: return "Versão \(entry.installed?.version.description ?? "?") em \(folder)."
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            switch entry.phase {
            case .notInstalled:
                Button("Instalar") { tools.install(entry) }.buttonStyle(.borderedProminent)
            case .updateAvailable:
                Button("Atualizar") { tools.install(entry) }.buttonStyle(.borderedProminent)
            case .installed:
                if !entry.isRunning { Button("Abrir") { tools.open(entry) }.buttonStyle(.borderedProminent) }
            }
            if entry.installed != nil {
                if entry.phase == .updateAvailable, !entry.isRunning { Button("Abrir") { tools.open(entry) } }
                Button("Remover") { confirmingRemoval = true }
            }
            if let busy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            }
        }
        .controlSize(.large)
        .disabled(busy != nil)
    }
}

private struct ToolGuide: View {
    let steps: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if steps.isEmpty { Hint(text: "Esta tool não tem guia.") }
            ForEach(steps.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 14) {
                    Text("\(index + 1)")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(tint.opacity(0.16)))
                    Text(steps[index]).fixedSize(horizontal: false, vertical: true).padding(.top, 5)
                }
            }
        }
        .card(padding: 26)
    }
}

struct ToolIcon: View {
    let tool: ToolBundle
    var size: CGFloat = 40

    var body: some View {
        if tool.iconURL != nil {
            Image(nsImage: NSWorkspace.shared.icon(forFile: tool.url.path)).resizable().frame(width: size, height: size)
        } else {
            IconTile(symbol: tool.symbol ?? "app", tint: tool.tintColor, size: size, filled: true)
        }
    }
}
