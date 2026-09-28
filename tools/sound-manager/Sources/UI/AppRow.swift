import SwiftUI

struct AppRow: View {
    let app: AppItem
    let isBrowser: Bool
    @Binding var isExpanded: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var master: MasterVolume

    var body: some View {
        let setting = model.setting(for: app)
        let ceiling = master.level.volume
        let effective = VolumeCeiling.effectiveVolume(setting.volume, ceiling: ceiling)
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let failure = model.failures[app.id] {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .help(failure)
                    }
                }
                VolumeControl(
                    volume: effective,
                    muted: setting.muted,
                    ceiling: ceiling,
                    detail: setting.volume > effective ? "Limitado pelo volume geral. Valor salvo: \(Int((setting.volume * 100).rounded()))%." : nil,
                    onVolume: { model.setVolume($0, for: app) },
                    onToggleMute: { model.toggleMute(for: app) }
                )
            }
            if isBrowser {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Ocultar abas" : "Mostrar abas")
            } else {
                Spacer().frame(width: 20)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isExpanded ? Color.primary.opacity(0.06) : Color.clear))
    }
}
