import AppKit
import SwiftUI

struct ContributeView: View {
    // Static "Pix copia e cola" code: no fixed amount, so the payer types the value.
    static let pixCode = "00020101021126580014br.gov.bcb.pix0136ff715293-d963-459f-9ee2-d8fb83f615a25204000053039865802BR5923MARCELO DE O DO P CUNHA6008SALVADOR62070503***63041C28"

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
            Text("Leia o QR com o app do banco ou copie o código Pix. O valor é livre.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                if let image = QRCode.image(Self.pixCode, scale: 6) {
                    // White quiet zone so the bank app reads it on a dark window too.
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                }
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RECEBEDOR").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                        Text("Marcelo de O. do P. Cunha").font(.callout.weight(.medium))
                        Text("Salvador").font(.callout).foregroundStyle(.secondary)
                    }
                    Button(action: copy) {
                        Label(copied ? "Código copiado" : "Copiar código Pix", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    Text("No app do banco: Pix → Pix copia e cola.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.pixCode, forType: .string)
        copied = true
    }
}
