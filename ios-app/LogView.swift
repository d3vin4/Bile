import SwiftUI

struct LogView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager
    @State private var filter = ""
    @State private var showCredits = false

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
            .scrollContentBackground(.hidden)
            .background(Color.bileBackground.ignoresSafeArea())
            .searchable(text: $filter, prompt: lang("filter.logs"))
            .navigationTitle("\(lang("tab.logs")) (\(state.log.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        state.shareLogs()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(state.log.isEmpty)
                    Button {
                        showCredits = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    Button(lang("clear")) { state.log.removeAll() }
                }
            }
            .sheet(isPresented: $showCredits) {
                CreditsView()
            }
        }
        .navigationViewStyle(.stack)
    }

    private func color(for line: String) -> Color {
        if line.contains("✅") { return .green }
        if line.contains("❌") { return .red }
        if line.lowercased().contains("failed") || line.lowercased().contains("error") { return .orange }
        return .primary
    }
}
