import SwiftUI

struct MasterVolumeRow: View {
    @EnvironmentObject private var master: MasterVolume

    var body: some View {
        let device = master.device
        let level = master.level
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text("Volume geral")
                        .font(.system(size: 13, weight: .medium))
                        .layoutPriority(1)
                    Text(deviceCaption(device))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(device?.level.hasHardwareVolume == false ? "O dispositivo não tem volume próprio. O Sound Manager aplica o volume geral no áudio de cada app." : device?.name ?? "")
                }
                VolumeControl(
                    volume: level.volume,
                    muted: level.muted,
                    isEnabled: device != nil,
                    onVolume: master.setVolume,
                    onToggleMute: master.toggleMute
                )
            }
            Spacer().frame(width: 20)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }

    private func deviceCaption(_ device: MasterVolume.Device?) -> String {
        guard let device else { return "Sem saída de áudio" }
        return device.level.hasHardwareVolume ? device.name : "\(device.name) · por software"
    }
}
