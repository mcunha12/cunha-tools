import SwiftUI

struct UpdateBar: View {
    @EnvironmentObject private var updater: SuiteUpdater

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                if updater.isBusy { ProgressView().controlSize(.small) }
                Button("Checar atualizações", action: updater.checkAndUpdate)
                    .disabled(updater.source == nil || updater.isBusy)
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isFailure ? Color.red : Color.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isFailure: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private var status: String? {
        let branch = updater.source?.branch ?? "main"
        switch updater.phase {
        case .idle: return nil
        case .checking: return "Consultando o GitHub…"
        case .upToDate: return "Atualizado com o \(branch)."
        case .downloading: return "Baixando o \(branch)…"
        case .building: return "Compilando. Leva até 5 minutos."
        case .installing: return "Instalando. O Cunha Tools reabre em seguida."
        case .failed(let message): return message
        }
    }
}
