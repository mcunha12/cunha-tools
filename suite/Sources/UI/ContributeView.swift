import AppKit
import SwiftUI

struct ContributeView: View {
    static let pixKey = "marceloopcunha@gmail.com"

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "heart.fill", tint: .pink, size: 44, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Contribua").font(.title2.weight(.bold))
                    Text("O Cunha Tools é gratuito. O código está no GitHub.").foregroundStyle(.secondary)
                }
            }
            Text("Para contribuir, faça um Pix de qualquer valor para a chave abaixo.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("CHAVE PIX · E-MAIL").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(Self.pixKey)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(action: copy) {
                        Label(copied ? "Copiada" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.pixKey, forType: .string)
        copied = true
    }
}
