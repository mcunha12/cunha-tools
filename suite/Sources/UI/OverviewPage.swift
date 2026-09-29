import SwiftUI

struct OverviewPage: View {
    @EnvironmentObject private var tools: ToolsModel
    @EnvironmentObject private var phone: PhoneModel
    @Binding var page: Page
    let showsPhone: Bool

    private var total: Int { tools.entries.count }
    private var missing: Int { tools.entries.filter { $0.phase == .notInstalled }.count }
    private var updates: Int { tools.entries.filter { $0.phase == .updateAvailable }.count }
    private var unconfigured: [ToolsModel.Entry] { tools.entries.filter { $0.installed != nil && $0.status?.setupComplete == false } }
    private var open: Int { tools.entries.filter { $0.installed != nil && $0.isRunning }.count }
    private var installDir: String { InstallLocation.defaultDirectory.abbreviatedPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: "Início", subtitle: "Instala, atualiza e configura as tools deste Mac.") {
                StatusPill(text: pill.text, symbol: pill.symbol, color: pill.color, caption: "Versão \(Bundle.main.shortVersion)")
            }
            ViewThatFits(in: .horizontal) {
                cards(compact: false)
                cards(compact: true)
            }
            SectionHeader(title: "Tools", detail: "Instaladas em \(installDir)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                ForEach(tools.entries) { entry in
                    FeatureTile(title: entry.tool.name, subtitle: entry.tool.summary ?? "", symbol: entry.tool.symbol ?? "app", tint: entry.tool.tintColor, status: (entry.state.text, entry.state.color)) {
                        page = .tool(entry.id)
                    }
                }
                if showsPhone {
                    FeatureTile(title: "Celular", subtitle: "Pareamento adb e app companheiro no Android.", symbol: "iphone", tint: Palette.accent, status: (phone.summary.title, phone.summary.color)) {
                        page = .phone
                    }
                }
            }
        }
    }

    private var pill: (text: String, symbol: String, color: Color) {
        if updates > 0 { return (counted(updates, "atualização", "atualizações"), "arrow.triangle.2.circlepath", .orange) }
        if missing > 0 { return ("\(missing) para instalar", "arrow.down.circle.fill", Palette.accent) }
        if !unconfigured.isEmpty { return ("\(unconfigured.count) para configurar", "exclamationmark.circle.fill", .orange) }
        return ("Tudo em dia", "checkmark.circle.fill", .green)
    }

    private var headline: String {
        if total == 0 { return "Nenhuma tool nesta versão." }
        if missing > 0, updates > 0 { return "Instale e atualize suas tools." }
        if missing > 0 { return "Instale suas tools." }
        if updates > 0 { return "Atualize suas tools." }
        if !unconfigured.isEmpty { return "Falta configurar \(counted(unconfigured.count, "tool", "tools"))." }
        return "Tudo instalado e em dia."
    }

    private var summary: String {
        let copies = "O Cunha Tools copia cada uma para \(installDir) e abre ao terminar."
        if total == 0 { return "Esta versão do Cunha Tools não traz tools embutidas." }
        if missing > 0, updates > 0 { return "\(missing) para instalar e \(updates) para atualizar. \(copies)" }
        if missing > 0 { return "\(missing == 1 ? "Falta" : "Faltam") \(missing) de \(counted(total, "tool", "tools")). \(copies)" }
        if updates > 0 { return "\(counted(updates, "tool tem", "tools têm")) versão nova nesta suíte. A atualização fecha a tool, troca a cópia e abre de novo." }
        if !unconfigured.isEmpty {
            let names = unconfigured.map(\.tool.name).joined(separator: ", ")
            return "\(names) \(unconfigured.count == 1 ? "precisa" : "precisam") de configuração. A página da tool mostra o que falta."
        }
        return "\(counted(total, "tool instalada", "tools instaladas")) na versão desta suíte. A página de cada tool tem a configuração e o guia."
    }

    // The compact ring card puts the legend under the ring, so both cards share one row at the window's minimum width.
    private func cards(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 20) {
            hero.frame(idealWidth: 364, maxWidth: .infinity, maxHeight: .infinity)
            ring(compact: compact).frame(width: compact ? 200 : 356).frame(maxHeight: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                IconTile(symbol: "wrench.and.screwdriver.fill", tint: Palette.accent, size: 56, filled: true)
                Spacer()
                Text(counted(total, "tool", "tools")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 30)
            Text(headline).font(.system(size: 30, weight: .bold)).padding(.bottom, 10)
            Text(summary).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 30)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { primaryAction; bundledNote }
                VStack(alignment: .leading, spacing: 12) { primaryAction; bundledNote }
            }
        }
        .card(padding: 30)
    }

    @ViewBuilder
    private var bundledNote: some View {
        if !tools.pending.isEmpty { Label("As tools vêm dentro do app", systemImage: "shippingbox").foregroundStyle(.secondary) }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let label = tools.busy.values.first {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(label).foregroundStyle(.secondary)
            }
            .frame(height: 30)
        } else if tools.pending.isEmpty, let first = unconfigured.first {
            Button { page = .tool(first.id) } label: { Label("Configurar", systemImage: "gearshape.fill") }
                .help("Abre a página do \(first.tool.name)")
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else if tools.pending.isEmpty {
            Label("Nada pendente", systemImage: "checkmark.circle.fill").foregroundStyle(.green).frame(height: 30)
        } else {
            Button(action: tools.installPending) {
                Label(missing > 0 && updates > 0 ? "Instalar e atualizar" : missing > 0 ? "Instalar tudo" : "Atualizar tudo", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func ring(compact: Bool) -> some View {
        let layout = compact ? AnyLayout(VStackLayout(spacing: 22)) : AnyLayout(HStackLayout(spacing: 20))
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tools no Mac").font(.title2.weight(.semibold))
                    Text("\(total - missing) de \(total) instaladas").foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: tools.refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .help("Ler de novo as tools instaladas")
            }
            layout {
                StatusRing(segments: [(open, Palette.accent), (total - missing - open, Palette.closed)], total: total) {
                    VStack(spacing: 2) {
                        Text("\(total - missing)/\(total)").font(.system(size: 26, weight: .bold).monospacedDigit())
                        Text("INSTALADAS").font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: 14) {
                    LegendRow(color: Palette.accent, label: "Abertas", value: open)
                    LegendRow(color: Palette.closed, label: "Fechadas", value: total - missing - open)
                    LegendRow(color: Palette.track, label: "Não instaladas", value: missing)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 26)
    }
}

struct StatusRing<Center: View>: View {
    let segments: [(value: Int, color: Color)]
    let total: Int
    var lineWidth: CGFloat = 18
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: lineWidth)
            ForEach(arcs.indices, id: \.self) { index in
                Circle()
                    .trim(from: arcs[index].start, to: arcs[index].end)
                    .stroke(arcs[index].color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .padding(lineWidth / 2)
    }

    // A thin gap separates segments, except when one segment fills the whole ring.
    private var arcs: [(start: Double, end: Double, color: Color)] {
        guard total > 0 else { return [] }
        var start = 0.0
        var result: [(start: Double, end: Double, color: Color)] = []
        for segment in segments where segment.value > 0 {
            let end = start + Double(segment.value) / Double(total)
            result.append((start, segment.value == total ? end : max(start, end - 0.01), segment.color))
            start = end
        }
        return result
    }
}

private struct LegendRow: View {
    let color: Color
    let label: String
    let value: Int

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 8)
            Text("\(value)").font(.body.weight(.semibold).monospacedDigit())
        }
    }
}

struct FeatureTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let status: (text: String, color: Color)
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button(action: action) {
            HStack(spacing: 16) {
                IconTile(symbol: symbol, tint: tint, size: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Circle().fill(status.color).frame(width: 6, height: 6)
                        Text(status.text).font(.callout).foregroundStyle(status.color)
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
            .background(shape.fill(Palette.card))
            .overlay(shape.strokeBorder(hovering ? tint.opacity(0.55) : Color.primary.opacity(0.05)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
