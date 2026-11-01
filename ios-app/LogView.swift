import SwiftUI

struct LogView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationView {
            List(state.log, id: \.self) { line in
                Text(line).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(logColor(line))
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { state.log.removeAll() }
                }
            }
        }
    }

    func logColor(_ line: String) -> Color {
        if line.contains("✅") { return .green }
        if line.contains("❌") { return .red }
        return .secondary
    }
}
