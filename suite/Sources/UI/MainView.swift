import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var tools: ToolsModel
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView { content }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            SectionTitle(text: "Ferramentas")
            if tools.entries.isEmpty {
                Text("Esta versão da suíte não tem tools.").foregroundStyle(.secondary)
            }
            ForEach(tools.entries) { ToolCard(entry: $0) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cunha Tools").font(.title2.weight(.semibold))
                Text(versionLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            UpdateBar()
        }
    }

    private var versionLine: String {
        let commit = SuiteUpdater.installedCommit.map { " · commit \($0.prefix(7))" } ?? ""
        return "Versão \(Bundle.main.shortVersion)\(commit) · instala em \(InstallLocation.defaultDirectory.abbreviatedPath)"
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text).font(.headline)
    }
}

extension View {
    func card() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
}

extension URL {
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
