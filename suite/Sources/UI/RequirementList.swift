import SwiftUI

// Each tool asks macOS for its own permissions; the suite only shows what the tool publishes.
struct RequirementList: View {
    let entry: ToolsModel.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entry.tool.requirements, id: \.self) { requirement in
                let state = state(of: requirement)
                HStack(spacing: 6) {
                    Image(systemName: state.symbol).foregroundStyle(state.color)
                    Text(requirement.title)
                    Text("· \(state.text)").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            if entry.installed != nil, let detail = entry.status?.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func state(of requirement: ToolRequirement) -> (symbol: String, color: Color, text: String) {
        guard entry.installed != nil else { return ("circle", .secondary, "a tool pede após instalar") }
        switch entry.status?.setupComplete {
        case true?: return ("checkmark.circle.fill", .green, "concedida")
        case false?: return ("exclamationmark.circle.fill", .orange, "pendente, clique em Configurar")
        case nil: return ("circle.dashed", .secondary, "abra a tool para conferir")
        }
    }
}
