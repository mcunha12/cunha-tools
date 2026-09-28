import SwiftUI

struct BrowserTabsSection: View {
    let app: AppItem
    @EnvironmentObject private var bridge: BrowserBridge

    var body: some View {
        let sessions = bridge.sessions(matchingAppNamed: app.name, bundleID: app.bundleID)
        VStack(alignment: .leading, spacing: 2) {
            if sessions.isEmpty {
                ExtensionSetupView(app: app)
            } else {
                let tabs = sessions.flatMap { session in
                    session.tabs.filter(\.hasSound).map { SessionTab(session: session.id, tab: $0) }
                }
                if tabs.isEmpty {
                    Text("Nenhuma aba tocando som.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                ForEach(tabs) { item in
                    TabRow(tab: item.tab, session: item.session)
                }
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, 34)
        .padding(.bottom, 6)
    }
}

private struct SessionTab: Identifiable {
    let session: UUID
    let tab: BrowserTab

    var id: String { "\(session.uuidString)-\(tab.id)" }
}

private struct TabRow: View {
    let tab: BrowserTab
    let session: UUID
    @EnvironmentObject private var bridge: BrowserBridge
    @State private var draftVolume: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Favicon(url: tab.favIconUrl)
                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(tab.url)
            }
            VolumeControl(
                volume: draftVolume ?? tab.volume,
                muted: tab.muted,
                isEnabled: tab.volumeSupported,
                onVolume: { volume in
                    draftVolume = volume
                    bridge.setVolume(volume, tab: tab, session: session)
                },
                onToggleMute: { bridge.setMuted(!tab.muted, tab: tab, session: session) }
            )
        }
        .padding(.vertical, 3)
        .onChange(of: tab.volume) { _, confirmed in
            if let draft = draftVolume, abs(draft - confirmed) < 0.005 { draftVolume = nil }
        }
    }
}

private struct Favicon: View {
    let url: String?

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url), ["http", "https", "data"].contains(parsed.scheme ?? "") {
                AsyncImage(url: parsed) { image in
                    image.resizable().interpolation(.high)
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(width: 14, height: 14)
    }

    private var placeholder: some View {
        Image(systemName: "globe").resizable().foregroundStyle(.secondary)
    }
}

private struct ExtensionSetupView: View {
    let app: AppItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Para controlar cada aba, instale a extensão do Sound Manager no \(app.name):")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text("1. Clique em “Instalar extensão”.\n2. Na página de extensões, ative o “Modo do desenvolvedor”.\n3. Clique em “Carregar sem compactação” e escolha a pasta aberta no Finder (o caminho já está copiado).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Instalar extensão") { ExtensionInstaller.install(for: app) }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}
