import Foundation
import SwiftUI

/// Small app-wide state: the log buffer and the share sheet.
/// Everything else lives in the tab's own observable model.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedTab: AppTab = .files
    @Published var log: [String] = []
    @Published var exportedFileURL: URL? = nil
    @Published var showShareSheet: Bool = false

    init() {
        logLine("Bile ready")
    }

    func logLine(_ s: String) {
        let stamp = Self.stamp()
        log.append("[\(stamp)] \(s)")
        // Keep the buffer bounded so long sessions never slow appends down.
        if log.count > 4000 {
            log.removeFirst(log.count - 4000)
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    /// Opens the share sheet with one file URL.
    func share(url: URL) {
        exportedFileURL = url
        showShareSheet = true
    }

    /// Writes the log to a text file and hands it to the share sheet.
    func shareLogs() {
        let text = log.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bile-log-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            share(url: url)
        } catch {
            logLine("Could not write the log file: \(error.localizedDescription)")
        }
    }
}
