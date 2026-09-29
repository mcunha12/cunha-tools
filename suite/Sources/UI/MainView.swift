import AppKit
import SwiftUI

enum Page: Hashable {
    case overview
    case tool(String)
    case phone
}

struct MainView: View {
    @EnvironmentObject private var tools: ToolsModel
    @State private var page = Page.overview

    var body: some View {
        NavigationSplitView {
            Sidebar(page: $page, showsPhone: tools.needsPhone)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 320)
        } detail: {
            ScrollView { PageContent(page: $page, showsPhone: tools.needsPhone) }
                .background(Palette.canvas)
                .navigationTitle("Cunha Tools")
        }
        .tint(Palette.accent)
    }
}

struct PageContent: View {
    @EnvironmentObject private var tools: ToolsModel
    @Binding var page: Page
    let showsPhone: Bool
    var opensGuide = false

    var body: some View {
        Group {
            switch page {
            case .overview:
                OverviewPage(page: $page, showsPhone: showsPhone)
            case .phone:
                PhonePage()
            case let .tool(id):
                if let entry = tools.entries.first(where: { $0.id == id }) {
                    ToolPage(entry: entry, page: $page, opensGuide: opensGuide).id(id)
                } else {
                    OverviewPage(page: $page, showsPhone: showsPhone)
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ToolsModel.Entry {
    // One status per tool, shared by the sidebar, the tiles and the tool page.
    var state: (text: String, symbol: String, color: Color) {
        switch phase {
        case .notInstalled: return ("Não instalada", "arrow.down.circle", .secondary)
        case .updateAvailable: return ("Atualização disponível", "arrow.triangle.2.circlepath", .orange)
        case .installed:
            if status?.setupComplete == false { return ("Falta configurar", "exclamationmark.circle.fill", .orange) }
            return isRunning ? ("Aberta", "checkmark.circle.fill", Palette.accent) : ("Instalada", "checkmark.circle", Palette.closed)
        }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
}

extension URL {
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }

    // /tmp and /private/tmp compare equal.
    var realPath: String { resolvingSymlinksInPath().path }
}
