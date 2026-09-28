import CunhaKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var bridge: BrowserBridge
    @EnvironmentObject private var launchAtLogin: LaunchAtLogin
    @State private var expanded: Set<String>

    init(initiallyExpanded: Set<String> = []) {
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            MasterVolumeRow()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            Divider()
            if model.permission != .authorized {
                PermissionBanner(isDenied: model.permission == .denied, action: model.requestPermission)
                Divider()
            }
            ScrollView {
                VStack(spacing: 2) {
                    let apps = visibleApps
                    if apps.isEmpty {
                        Text("Nenhum app tocando som agora.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                    ForEach(apps) { app in
                        let isBrowser = BrowserCatalog.isExtensionBrowser(app.bundleID)
                        AppRow(app: app, isBrowser: isBrowser, isExpanded: expansion(for: app))
                        if isBrowser, expanded.contains(app.id) {
                            BrowserTabsSection(app: app)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear(perform: launchAtLogin.refresh)
    }

    private var footer: some View {
        HStack {
            Toggle("Abrir ao iniciar o Mac", isOn: Binding(get: { launchAtLogin.isEnabled }, set: launchAtLogin.setEnabled))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(!launchAtLogin.isInstalled)
                .help(launchAtLogin.isInstalled ? "" : "Mova o Sound Manager para a pasta Aplicativos para ativar.")
            if launchAtLogin.needsApproval {
                Button("Aprovar nos Ajustes", action: launchAtLogin.openLoginItemsSettings)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if let error = bridge.listenerError {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Extensão indisponível: \(error)")
            }
            Spacer()
            Button("Sair") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var visibleApps: [AppItem] {
        let audible = Set(model.audibleApps.map(\.id))
        return model.apps.filter { app in
            let sessions = BrowserCatalog.isExtensionBrowser(app.bundleID) ? bridge.sessions(matchingAppNamed: app.name, bundleID: app.bundleID) : []
            return sessions.isEmpty ? audible.contains(app.id) : !bridge.tabsWithSound(in: sessions).isEmpty
        }
    }

    private func expansion(for app: AppItem) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(app.id) },
            set: { isOn in
                if isOn { expanded.insert(app.id) } else { expanded.remove(app.id) }
            }
        )
    }
}

private struct PermissionBanner: View {
    let isDenied: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text(isDenied
                     ? "O acesso a “Gravação de áudio do sistema” está negado. Libere o Sound Manager nos Ajustes para controlar o volume por app."
                     : "O controle de volume por app exige a permissão “Gravação de áudio do sistema”.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button(isDenied ? "Abrir Ajustes" : "Permitir", action: action)
                    .controlSize(.small)
            }
        }
        .padding(12)
    }
}
