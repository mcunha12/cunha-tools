import AppKit
import ServiceManagement
import SwiftUI

struct ToolCard: View {
    @EnvironmentObject private var tools: ToolsModel
    let entry: ToolsModel.Entry
    @State private var confirmingRemoval = false

    private var tool: ToolBundle { entry.tool }
    private var busy: String? { tools.busy[entry.id] }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ToolIcon(tool: tool)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(tool.name).font(.headline)
                    badges
                    Spacer(minLength: 0)
                }
                if let summary = tool.summary { Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                Text(versionLine).font(.caption).foregroundStyle(.secondary)
                if !tool.requirements.isEmpty { RequirementList(entry: entry) }
                actions
                if entry.installed != nil { loginRow }
                if let error = tools.errors[entry.id] {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card()
        .confirmationDialog("Remover \(tool.name)?", isPresented: $confirmingRemoval) {
            Button("Mover para o Lixo", role: .destructive) { tools.remove(entry) }
        } message: {
            Text("A tool fecha, deixa de abrir ao iniciar o Mac e vai para o Lixo.")
        }
    }

    @ViewBuilder
    private var badges: some View {
        switch entry.phase {
        case .notInstalled: Badge(text: "Não instalada", color: .secondary)
        case .updateAvailable: Badge(text: "Atualização disponível", color: .orange)
        case .installed: if !entry.isRunning { Badge(text: "Instalada", color: .green) }
        }
        if entry.isRunning, entry.installed != nil { Badge(text: "Aberta", color: .blue) }
    }

    private var versionLine: String {
        guard let installed = entry.installed else { return "Versão \(tool.version)" }
        let location = "em \(installed.url.deletingLastPathComponent().abbreviatedPath)"
        if entry.phase == .updateAvailable { return "Instalada \(installed.version) \(location) · nova \(tool.version)" }
        return "Instalada \(installed.version) \(location)"
    }

    private var actions: some View {
        HStack(spacing: 8) {
            switch entry.phase {
            case .notInstalled: Button("Instalar") { tools.install(entry) }.buttonStyle(.borderedProminent)
            case .updateAvailable: Button("Atualizar") { tools.install(entry) }.buttonStyle(.borderedProminent)
            case .installed: EmptyView()
            }
            if entry.installed != nil {
                if !entry.isRunning { Button("Abrir") { tools.open(entry) } }
                Button("Configurar") { tools.configure(entry) }
                Button("Remover") { confirmingRemoval = true }
            }
            if let busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(busy != nil)
    }

    private var loginRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Abrir ao iniciar o Mac", isOn: Binding(
                get: { tools.launchAtLogin(entry) },
                set: { tools.setLaunchAtLogin($0, for: entry) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            if entry.status?.needsApproval == true {
                HStack(spacing: 6) {
                    Text("Falta aprovar em Ajustes do Sistema → Geral → Itens de início.").font(.caption).foregroundStyle(.orange)
                    Button("Abrir Ajustes") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                }
            }
        }
    }
}

struct ToolIcon: View {
    let tool: ToolBundle

    var body: some View {
        Group {
            if tool.iconURL != nil {
                Image(nsImage: NSWorkspace.shared.icon(forFile: tool.url.path)).resizable()
            } else {
                Image(systemName: tool.symbol ?? "app")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(0.12)))
            }
        }
        .frame(width: 40, height: 40)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
