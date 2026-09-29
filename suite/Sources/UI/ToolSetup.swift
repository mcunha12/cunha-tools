import ServiceManagement
import SwiftUI

// Audio capture and local network are granted inside the tool; the phone comes from the Celular page.
struct ToolSetup: View {
    @EnvironmentObject private var tools: ToolsModel
    @EnvironmentObject private var phone: PhoneModel
    let entry: ToolsModel.Entry
    @Binding var page: Page

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if entry.tool.requirements.isEmpty, entry.installed == nil {
                Hint(text: "Esta tool não pede permissões. Instale para ligar a abertura ao iniciar o Mac.")
            }
            ForEach(Array(entry.tool.requirements.enumerated()), id: \.element) { index, requirement in
                if index > 0 { Divider() }
                row(requirement)
            }
            if entry.installed != nil {
                if !entry.tool.requirements.isEmpty { Divider() }
                loginRow
            }
            if entry.installed != nil, let detail = entry.status?.detail, !detail.isEmpty { Hint(text: detail) }
        }
        .card(padding: 24)
    }

    private func row(_ requirement: ToolRequirement) -> some View {
        let state = state(of: requirement)
        return SetupRow(symbol: requirement.symbol, tint: state.color, title: requirement.title, detail: state.text) {
            if requirement == .phone {
                if !phone.isReady { Button("Abrir Celular") { page = .phone } }
            } else if entry.installed != nil, entry.status?.setupComplete != true {
                Button("Configurar") { tools.configure(entry) }.disabled(tools.busy[entry.id] != nil)
            } else {
                Image(systemName: state.symbol).foregroundStyle(state.color).font(.title3)
            }
        }
    }

    private var loginRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            SetupRow(symbol: "power", tint: Palette.accent, title: "Abrir ao iniciar o Mac", detail: "A tool abre sozinha no login.") {
                Toggle("Abrir ao iniciar o Mac", isOn: Binding(
                    get: { tools.launchAtLogin(entry) },
                    set: { tools.setLaunchAtLogin($0, for: entry) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if entry.status?.needsApproval == true {
                HStack(spacing: 8) {
                    Text("Falta aprovar em Ajustes do Sistema → Geral → Itens de início.").font(.caption).foregroundStyle(.orange)
                    Button("Abrir Ajustes") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                }
                .padding(.leading, 50)
            }
        }
    }

    private func state(of requirement: ToolRequirement) -> (symbol: String, color: Color, text: String) {
        if requirement == .phone {
            if phone.isReady { return ("checkmark.circle.fill", .green, "Pronto.") }
            if phone.device != nil { return ("exclamationmark.circle.fill", .orange, "Falta o app companheiro.") }
            return ("circle", .secondary, "Pareie o celular na página Celular.")
        }
        guard entry.installed != nil else { return ("circle", .secondary, "A tool pede depois de instalar.") }
        switch entry.status?.setupComplete {
        case true?: return ("checkmark.circle.fill", .green, "Concedida.")
        case false?: return ("exclamationmark.circle.fill", .orange, "Pendente. Clique em Configurar para a tool pedir de novo.")
        case nil: return ("circle.dashed", .secondary, "Abra a tool para conferir.")
        }
    }
}

struct SetupRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: symbol, tint: tint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}
