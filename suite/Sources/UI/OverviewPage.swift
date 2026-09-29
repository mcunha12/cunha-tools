import SwiftUI

struct OverviewPage: View {
    @EnvironmentObject private var tools: ToolsModel
    @EnvironmentObject private var phone: PhoneModel
    @Binding var page: Page
    let showsPhone: Bool

    private var total: Int { tools.entries.count }
    private var missing: Int { tools.entries.filter { $0.phase == .notInstalled }.count }
    private var updates: Int { tools.entries.filter { $0.phase == .updateAvailable }.count }
    private var unconfigured: Int { tools.entries.filter { $0.installed != nil && $0.status?.setupComplete == false }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: "Início", subtitle: "Instala, atualiza e configura as tools deste Mac.") {
                StatusPill(text: pill.text, symbol: pill.symbol, color: pill.color, caption: "Versão \(Bundle.main.shortVersion)")
            }
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 12)
                ForEach(tools.entries) { entry in
                    Divider()
                    OverviewRow(title: entry.tool.name, symbol: entry.tool.symbol ?? "app", tint: entry.tool.tintColor, status: (entry.state.text, entry.state.color), action: action(for: entry), isBusy: tools.busy[entry.id] != nil) {
                        page = .tool(entry.id)
                    }
                }
                if showsPhone {
                    Divider()
                    OverviewRow(title: "Celular", symbol: "iphone", tint: Palette.accent, status: (phone.summary.title, phone.summary.color), action: phone.isReady ? nil : ("Parear", false)) {
                        page = .phone
                    }
                }
            }
            .card(padding: 18)
        }
    }

    private var pill: (text: String, symbol: String, color: Color) {
        if updates > 0 { return (counted(updates, "atualização", "atualizações"), "arrow.triangle.2.circlepath", .orange) }
        if missing > 0 { return ("\(missing) para instalar", "arrow.down.circle.fill", Palette.accent) }
        if unconfigured > 0 { return ("\(unconfigured) para configurar", "exclamationmark.circle.fill", .orange) }
        return ("Tudo em dia", "checkmark.circle.fill", .green)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tools").font(.title2.weight(.semibold))
                Text(total == 0 ? "Nenhuma tool nesta versão." : "\(total - missing) de \(total) \(total == 1 ? "instalada" : "instaladas")").foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: tools.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .help("Ler de novo as tools instaladas")
        }
        .padding(.horizontal, 10)
    }

    // Rows only navigate; install, update and setup run on the tool page.
    private func action(for entry: ToolsModel.Entry) -> (label: String, prominent: Bool)? {
        switch entry.phase {
        case .notInstalled: return ("Instalar", true)
        case .updateAvailable: return ("Atualizar", true)
        case .installed: return entry.status?.setupComplete == false ? ("Configurar", false) : nil
        }
    }
}

private struct OverviewRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let status: (text: String, color: Color)
    let action: (label: String, prominent: Bool)?
    var isBusy = false
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 14) {
                IconTile(symbol: symbol, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(status.color).frame(width: 6, height: 6)
                        Text(status.text).font(.callout).foregroundStyle(status.color).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if let action, action.prominent {
                    Button(action.label, action: open).buttonStyle(.borderedProminent)
                } else if let action {
                    Button(action.label, action: open).buttonStyle(.bordered)
                } else {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
