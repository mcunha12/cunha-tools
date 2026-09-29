import AppKit
import CunhaKit
import SwiftUI

struct ToolPage: View {
    @EnvironmentObject private var tools: ToolsModel
    let entry: ToolsModel.Entry
    @Binding var page: Page
    @StateObject private var remote = SoundManagerRemote()
    @State private var guideExpanded: Bool
    @State private var confirmingRemoval = false

    init(entry: ToolsModel.Entry, page: Binding<Page>, opensGuide: Bool = false) {
        self.entry = entry
        _page = page
        _guideExpanded = State(initialValue: opensGuide)
    }

    private var tool: ToolBundle { entry.tool }
    private var busy: String? { tools.busy[entry.id] }
    private var isSoundManager: Bool { entry.id == SoundChannel.bundleID }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: tool.name, subtitle: tool.summary ?? "") {
                StatusPill(text: entry.state.text, symbol: entry.state.symbol, color: entry.state.color, caption: "Versão \(entry.installed?.version ?? tool.version)")
            }
            hero
            if isSoundManager { VolumesCard(remote: remote, entry: entry) }
            ToolSetup(entry: entry, page: $page, remote: isSoundManager ? remote : nil)
            if !tool.guide.isEmpty { ToolGuide(steps: tool.guide, isExpanded: $guideExpanded) }
        }
        .onAppear { if isSoundManager { remote.start() } }
        .onDisappear(perform: remote.stop)
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

// Usage steps, collapsed at the bottom of the page.
private struct ToolGuide: View {
    let steps: [String]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps.indices, id: \.self) { index in
                    Text("\(index + 1). \(steps[index])").fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Text("Como usar").font(.callout.weight(.medium)).foregroundStyle(.secondary)
        }
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
