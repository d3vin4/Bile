import SwiftUI

struct LogView: View {
    @EnvironmentObject var state: AppState
    @State private var filter = ""

    private var lines: [String] {
        let query = filter.lowercased()
        guard !query.isEmpty else { return state.log }
        return state.log.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        NavigationView {
            List(lines, id: \.self) { line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(color(for: line))
                    .textSelection(.enabled)
            }
            .listStyle(.plain)
            .searchable(text: $filter, prompt: "Filter logs")
            .navigationTitle("Logs (\(state.log.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        state.shareLogs()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(state.log.isEmpty)
                    Button("Clear") { state.log.removeAll() }
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("✅") { return .green }
        if line.contains("❌") { return .red }
        if line.lowercased().contains("failed") || line.lowercased().contains("error") { return .orange }
        if line.hasPrefix("export: ") { return .secondary }
        return .primary
    }
}
