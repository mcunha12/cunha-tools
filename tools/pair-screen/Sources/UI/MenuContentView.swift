import CunhaKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var mirror: MirrorController
    @EnvironmentObject private var settings: MirrorSettings
    @EnvironmentObject private var launchAtLogin: LaunchAtLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                header
                if mirror.state == .noDevice {
                    Button("Abrir Cunha Tools", action: mirror.openSuite)
                        .controlSize(.small)
                }
                actions
                if let note = mirror.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            Divider()
            preferences.padding(12)
            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear {
            launchAtLogin.refresh()
            Task { await mirror.refreshDevice() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: mirror.state == .streaming ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button(mirror.isActive ? "Desconectar" : "Conectar") {
                if mirror.isActive { mirror.disconnect() } else { mirror.connect() }
            }
            .keyboardShortcut(.defaultAction)
            Button(mirror.overlayVisible ? "Ocultar janela" : "Mostrar janela", action: mirror.toggleOverlay)
                .disabled(!mirror.isActive)
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                pickerRow("Resolução máxima", selection: $settings.maxSize, values: MirrorSettings.maxSizeChoices) { $0 == 0 ? "Original" : "\($0) px" }
                pickerRow("FPS máximo", selection: $settings.maxFps, values: MirrorSettings.fpsChoices) { "\($0)" }
                pickerRow("Bitrate", selection: $settings.bitRateMbps, values: MirrorSettings.bitRateChoices) { "\($0) Mbps" }
                pickerRow("Codec", selection: $settings.codec, values: VideoCodec.allCases) { $0.label }
            }
            Toggle("Desligar a tela do celular durante o espelhamento", isOn: $settings.turnScreenOff)
            Toggle("Sempre no topo", isOn: $settings.alwaysOnTop)
        }
        .font(.callout)
        .toggleStyle(.checkbox)
    }

    private func pickerRow<Value: Hashable>(_ label: String, selection: Binding<Value>, values: [Value], text: @escaping (Value) -> String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                ForEach(values, id: \.self) { Text(text($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Abrir ao iniciar o Mac", isOn: Binding(get: { launchAtLogin.isEnabled }, set: launchAtLogin.setEnabled))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(!launchAtLogin.isInstalled)
                .help(launchAtLogin.isInstalled ? "" : "Mova o Pair Screen para a pasta Aplicativos para ativar.")
            if launchAtLogin.needsApproval {
                Button("Aprovar nos Ajustes", action: launchAtLogin.openLoginItemsSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer()
            Button("Sair") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var title: String {
        switch mirror.state {
        case .streaming: mirror.deviceName ?? "Celular"
        case .connecting: "Conectando…"
        case .reconnecting: "Reconectando…"
        case .noDevice: "Nenhum celular conectado"
        case .failed: "Falha ao conectar"
        case .idle: mirror.availableDevice ?? "Pair Screen"
        }
    }

    private var subtitle: String {
        switch mirror.state {
        case .streaming: "Espelhando. Clique e digite na janela para controlar."
        case .connecting: "Iniciando o espelhamento no celular."
        case .reconnecting: "A conexão caiu. Volto sozinho quando o celular aparecer."
        case .noDevice: "Pareie o celular no Cunha Tools, por USB ou depuração sem fio."
        case let .failed(message): message
        case .idle: mirror.availableDevice == nil ? "Nenhum celular conectado." : "Pronto para espelhar."
        }
    }
}
