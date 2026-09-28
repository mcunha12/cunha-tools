import SwiftUI

struct VolumeControl: View {
    let volume: Double
    let muted: Bool
    var ceiling: Double = 1
    var isEnabled = true
    var detail: String?
    let onVolume: (Double) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleMute) {
                Image(systemName: muted ? "speaker.slash.fill" : speakerSymbol)
                    .foregroundStyle(muted ? Color.red : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(muted ? "Ativar som" : "Silenciar")

            LevelSlider(value: volume, ceiling: ceiling, onChange: onVolume)
                .disabled(!isEnabled)
                .opacity(muted ? 0.45 : 1)

            Text("\(Int((volume * 100).rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .help(detail ?? "")
        }
    }

    private var speakerSymbol: String {
        switch volume {
        case 0: "speaker.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}
