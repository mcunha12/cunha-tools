import CunhaKit
import SwiftUI

// Sound Manager volumes, changed live over SoundChannel.
struct VolumesCard: View {
    @EnvironmentObject private var tools: ToolsModel
    @ObservedObject var remote: SoundManagerRemote
    let entry: ToolsModel.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if entry.isRunning, let state = remote.state {
                masterRow(state.output)
                Divider()
                if state.apps.isEmpty { Hint(text: "Nenhum app tocando som agora.") }
                ForEach(state.apps) { appRow($0, ceiling: state.ceiling) }
                if entry.status?.setupComplete == false { Hint(text: "Sem a permissão de áudio, só o volume geral muda.") }
            } else {
                unavailable
            }
        }
        .card(padding: 24)
    }

    private var unavailable: some View {
        HStack(spacing: 12) {
            Text(unavailableText).foregroundStyle(.secondary)
            if entry.installed != nil, !entry.isRunning {
                Button("Abrir") { tools.open(entry) }.disabled(tools.busy[entry.id] != nil)
            } else if entry.isRunning, !remote.isUnresponsive {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var unavailableText: String {
        if entry.installed == nil { return "Instale o Sound Manager para mudar os volumes aqui." }
        if !entry.isRunning { return "O Sound Manager está fechado." }
        if remote.isUnresponsive {
            return entry.phase == .updateAvailable ? "Atualize o Sound Manager para mudar os volumes aqui." : "O Sound Manager não respondeu."
        }
        return "Conectando ao Sound Manager…"
    }

    private func masterRow(_ output: SoundState.Output?) -> some View {
        VolumeRow(
            title: "Volume geral",
            detail: output.map { $0.isSoftware ? "\($0.name) · por software" : $0.name } ?? "Sem saída de áudio",
            volume: remote.masterVolume,
            muted: output?.muted ?? false,
            onVolume: { remote.setVolume($0, for: .master) },
            onToggleMute: { remote.toggleMute(for: .master) }
        ) {
            IconTile(symbol: "hifispeaker.fill", tint: Palette.accent, size: 36)
        }
        .disabled(output == nil)
    }

    private func appRow(_ app: SoundState.App, ceiling: Double) -> some View {
        VolumeRow(
            title: app.name,
            volume: remote.volume(of: app),
            muted: app.muted,
            ceiling: ceiling,
            help: app.volume > app.effectiveVolume ? "Limitado pelo volume geral. Valor salvo: \(Int((app.volume * 100).rounded()))%." : nil,
            onVolume: { remote.setVolume($0, for: .app(app.id)) },
            onToggleMute: { remote.toggleMute(for: .app(app.id)) }
        ) {
            Image(nsImage: remote.icon(for: app)).resizable().frame(width: 36, height: 36)
        }
    }
}

private struct VolumeRow<Icon: View>: View {
    let title: String
    var detail: String?
    let volume: Double
    let muted: Bool
    var ceiling: Double = 1
    var help: String?
    let onVolume: (Double) -> Void
    let onToggleMute: () -> Void
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 200, alignment: .leading)
            Button(action: onToggleMute) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(muted ? Color.red : Color.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? "Ativar som" : "Silenciar")
            LevelSlider(value: volume, ceiling: ceiling, onChange: onVolume)
                .opacity(muted ? 0.45 : 1)
            Text("\(Int((volume * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
                .help(help ?? "")
        }
    }
}
