import SwiftUI

struct PhoneSection: View {
    @EnvironmentObject private var phone: PhoneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepRow(number: 1, title: "Ferramentas Android", done: phone.adbURL != nil) { AndroidToolsStep() }
            Divider()
            StepRow(number: 2, title: "Preparar o celular", done: phone.device != nil) { PrepareStep() }
            Divider()
            StepRow(number: 3, title: "Parear", done: phone.device != nil) { PairStep() }
            Divider()
            StepRow(number: 4, title: "App companheiro", done: phone.companionVersion != nil) { CompanionStep() }
        }
        .card(padding: 24)
    }
}

struct StepRow<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .font(.title3)
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.semibold))
                content
            }
            Spacer(minLength: 0)
        }
    }
}

private struct AndroidToolsStep: View {
    @EnvironmentObject private var phone: PhoneModel

    var body: some View {
        if let url = phone.adbURL {
            Hint(text: "adb pronto em \(url.deletingLastPathComponent().abbreviatedPath).")
        } else if let progress = phone.downloadProgress {
            ProgressView(value: progress) { Text("Baixando platform-tools do Google…").font(.caption) }
                .frame(maxWidth: 280)
        } else {
            HStack(spacing: 8) {
                Button("Instalar ferramentas Android") { phone.installPlatformTools() }
                Hint(text: "Download de 16 MB do Google, 37 MB no disco.")
            }
            if let error = phone.downloadError { ErrorText(text: error) }
        }
    }
}

private struct PrepareStep: View {
    @EnvironmentObject private var phone: PhoneModel

    var body: some View {
        if phone.device != nil {
            Hint(text: "Celular pronto para depuração.")
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Hint(text: "1. Samsung: Configurações → Segurança e privacidade → Bloqueador automático → desligado.")
                Hint(text: "2. Configurações → Sobre o telefone → Informações de software → toque 7 vezes em \"Número de compilação\".")
                Hint(text: "3. Configurações → Opções do desenvolvedor → ligue \"Depuração sem fio\".")
            }
        }
    }
}

private struct CompanionStep: View {
    @EnvironmentObject private var phone: PhoneModel

    var body: some View {
        if phone.apkURL == nil {
            Hint(text: "Esta versão da suíte não tem o APK do app companheiro.")
        } else if phone.device == nil {
            Hint(text: "Conecte o celular para instalar.")
        } else {
            HStack(spacing: 8) {
                Button(phone.companionVersion == nil ? "Instalar no celular" : "Reinstalar") { phone.installCompanion() }
                    .disabled(phone.companionBusy)
                if phone.companionBusy {
                    ProgressView().controlSize(.small)
                    Hint(text: "Instalando e liberando permissões…")
                } else if let version = phone.companionVersion {
                    Hint(text: "Versão \(version) instalada.")
                }
            }
            if let error = phone.companionError { ErrorText(text: error) }
        }
    }
}

struct Hint: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct ErrorText: View {
    let text: String

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}
