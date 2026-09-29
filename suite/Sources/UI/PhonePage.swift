import SwiftUI

struct PhonePage: View {
    @EnvironmentObject private var phone: PhoneModel
    @EnvironmentObject private var tools: ToolsModel

    private var users: [String] { tools.entries.filter { $0.tool.requirements.contains(.phone) }.map(\.tool.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Celular", subtitle: subtitle) {
                StatusPill(text: phone.summary.title, symbol: phone.isReady ? "checkmark.circle.fill" : "iphone", color: phone.summary.color)
            }
            HStack(spacing: 20) {
                IconTile(symbol: "iphone", tint: phone.device == nil ? Color.secondary : Palette.accent, size: 60, filled: phone.device != nil)
                VStack(alignment: .leading, spacing: 6) {
                    Text(phone.device?.displayName ?? "Nenhum celular conectado").font(.system(size: 24, weight: .bold))
                    Text(phone.statusText).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .card(padding: 28)
            SectionHeader(title: "Configuração", detail: "4 etapas")
            PhoneSection()
        }
    }

    private var subtitle: String {
        guard !users.isEmpty else { return "Pareia o Android por adb." }
        let names = users.count == 1 ? users[0] : users.dropLast().joined(separator: ", ") + " e " + users[users.count - 1]
        return "Pareia o Android por adb. \(names) \(users.count == 1 ? "usa" : "usam") essa conexão."
    }
}

extension PhoneModel {
    var summary: (title: String, color: Color) {
        if device != nil { return companionVersion == nil ? ("Falta o app companheiro", .orange) : ("Celular pronto", .green) }
        if waitingDevice?.state == "unauthorized" { return ("Autorize a depuração", .orange) }
        return (adbURL == nil ? "Não configurado" : "Desconectado", .secondary)
    }

    var statusText: String {
        if let device {
            let link = device.isWireless ? "Wi-Fi" : "USB"
            let companion = companionVersion.map { "app companheiro \($0)" } ?? "sem app companheiro"
            return "\(link) · \(companion)"
        }
        if let waiting = waitingDevice {
            switch waiting.state {
            case "unauthorized": return "Celular aguardando você autorizar a depuração."
            case "offline": return "Celular encontrado, mas sem resposta. Desconecte e conecte de novo."
            default: return "Celular encontrado, estado \(waiting.state)."
            }
        }
        return adbURL == nil ? "Instale as ferramentas Android para conectar o celular." : "Siga as etapas abaixo para parear."
    }
}
