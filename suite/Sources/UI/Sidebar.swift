import AppKit
import SwiftUI

struct Sidebar: View {
    @EnvironmentObject private var tools: ToolsModel
    @EnvironmentObject private var phone: PhoneModel
    @Binding var page: Page
    let showsPhone: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarSection(title: "Geral")
                    SidebarRow(title: "Início", symbol: "square.grid.2x2.fill", tint: Palette.accent, isSelected: page == .overview) {
                        page = .overview
                    } trailing: {
                        if !tools.pending.isEmpty { CountBadge(count: tools.pending.count) }
                    }
                    SidebarSection(title: "Tools")
                    ForEach(tools.entries) { entry in
                        SidebarRow(title: entry.tool.name, symbol: entry.tool.symbol ?? "app", tint: entry.tool.tintColor, isSelected: page == .tool(entry.id)) {
                            page = .tool(entry.id)
                        } trailing: {
                            if entry.phase != .installed || entry.status?.setupComplete == false || entry.isRunning {
                                StatusDot(color: entry.state.color).help(entry.state.text)
                            }
                        }
                    }
                    if showsPhone {
                        SidebarSection(title: "Dispositivos")
                        SidebarRow(title: "Celular", symbol: "iphone", tint: Palette.accent, isSelected: page == .phone) {
                            page = .phone
                        } trailing: {
                            StatusDot(color: phone.summary.color).help(phone.summary.title)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            SidebarFooter()
        }
    }
}

struct SidebarSection: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.leading, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

struct SidebarRow<Trailing: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: tint, size: 28)
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                trailing
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? Palette.accent.opacity(0.18) : .clear))
            .overlay(alignment: .leading) {
                if isSelected { Capsule().fill(Palette.accent).frame(width: 3, height: 18).offset(x: -1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).padding(.trailing, 4)
    }
}

private struct SidebarFooter: View {
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @State private var showsContribution = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            UpdateCard()
            FooterButton(title: "Contribua", symbol: "heart.fill", tint: .pink) { showsContribution = true }
                .popover(isPresented: $showsContribution, arrowEdge: .trailing) { ContributeView() }
            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(Palette.accent).frame(width: 18)
                Text("Aparência")
                Spacer(minLength: 4)
                Picker("Aparência", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            .padding(.horizontal, 8)
            .onChange(of: appearance) { _, value in value.apply() }
        }
        .padding(12)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct UpdateCard: View {
    @EnvironmentObject private var updater: SuiteUpdater

    var body: some View {
        Button(action: updater.checkAndUpdate) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if updater.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol).foregroundStyle(color)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isFailure ? Color.red : Color.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(updater.source == nil || updater.isBusy)
        .help(helpText)
    }

    private var isFailure: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private var title: String {
        switch updater.phase {
        case .idle, .failed: return "Atualizar"
        case .checking: return "Consultando o GitHub"
        case .upToDate: return "Atualizado"
        case let .downloading(version): return "Baixando a versão \(version)"
        case .installing: return "Instalando"
        }
    }

    private var detail: String {
        if updater.source == nil { return "Sem repositório configurado." }
        switch updater.phase {
        case .idle: return "Versão \(Bundle.main.shortVersion) · \(SuiteUpdater.installedCommit.map { String($0.prefix(7)) } ?? "build local")"
        case .checking: return "Procura uma versão nova."
        case .upToDate: return "A versão \(Bundle.main.shortVersion) é a mais nova."
        case .downloading: return "\(UpdateSource.assetName) do GitHub."
        case .installing: return "O Cunha Tools reabre em seguida."
        case let .failed(message): return message
        }
    }

    private var symbol: String {
        switch updater.phase {
        case .upToDate: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var color: Color {
        switch updater.phase {
        case .upToDate: return .green
        case .failed: return .orange
        default: return Palette.accent
        }
    }

    private var helpText: String {
        guard let source = updater.source else { return "Falta CunhaUpdateRepository no Info.plist." }
        return "Baixa a versão mais nova de github.com/\(source.repository)/releases e troca o Cunha Tools e as tools instaladas."
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    static var current: Appearance { UserDefaults.standard.string(forKey: key).flatMap(Appearance.init(rawValue:)) ?? .system }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Sistema"
        case .light: "Claro"
        case .dark: "Escuro"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
