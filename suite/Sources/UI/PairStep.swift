import SwiftUI

struct PairStep: View {
    @EnvironmentObject private var phone: PhoneModel
    @State private var showsManual = false

    var body: some View {
        if let device = phone.device {
            Hint(text: device.isWireless ? "Conectado por Wi-Fi." : "Conectado por USB.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if phone.waitingDevice?.state == "unauthorized" {
                    Text("Toque em Permitir no aviso de depuração USB do celular.").font(.caption).foregroundStyle(.orange)
                }
                qr
                if let message = phone.pairingMessage { ErrorText(text: message) }
                DisclosureGroup("Parear com código", isExpanded: $showsManual) { manual }
                    .font(.caption)
            }
            .disabled(phone.adbURL == nil)
        }
    }

    @ViewBuilder
    private var qr: some View {
        switch phone.pairing {
        case .idle:
            HStack(spacing: 8) {
                Button("Mostrar QR de pareamento") { phone.startQRPairing() }
                Hint(text: "Ou conecte o cabo USB e autorize a depuração.")
            }
        case let .waitingForScan(session):
            HStack(alignment: .top, spacing: 12) {
                if let image = session.qrImage() {
                    // White quiet zone so the phone camera reads it on a dark window too.
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 150, height: 150)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Hint(text: "No celular: Opções do desenvolvedor → Depuração sem fio → Parear o dispositivo com um código QR.")
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Hint(text: "Aguardando o celular ler o QR…")
                    }
                    Button("Cancelar") { phone.stopPairing() }
                }
            }
        case .pairing:
            progress("Pareando…")
        case .connecting:
            progress("Pareado. Conectando…")
        }
    }

    private var manual: some View {
        VStack(alignment: .leading, spacing: 6) {
            Hint(text: "Depuração sem fio → Parear o dispositivo com código de pareamento.")
            HStack(spacing: 6) {
                TextField("IP:porta", text: $phone.manualPairAddress).frame(width: 170)
                TextField("Código", text: $phone.manualCode).frame(width: 80)
                Button("Parear") { phone.pairManually() }
                    .disabled(phone.manualPairAddress.isEmpty || phone.manualCode.isEmpty)
            }
            Hint(text: "Se parear e não conectar: IP e porta da tela Depuração sem fio.")
            HStack(spacing: 6) {
                TextField("IP:porta", text: $phone.manualConnectAddress).frame(width: 170)
                Button("Conectar") { phone.connectManually() }
                    .disabled(phone.manualConnectAddress.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.top, 4)
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Hint(text: text)
        }
    }
}
