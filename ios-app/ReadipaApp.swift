import SwiftUI

@main
struct ReadipaApp: App {
    @StateObject private var state = AppState.shared
    @StateObject private var pairing = PairingController.shared

    init() {
        _ = al_log_init({ _, msg in
            if let msg = msg {
                let line = String(cString: msg)
                DispatchQueue.main.async { AppState.shared.logLine(line) }
            }
        }, nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(pairing)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            SetupView().tabItem { Label("Setup", systemImage: "gear") }.tag(0)
            AppsView().tabItem { Label("Apps", systemImage: "app.badge") }.tag(1)
            BrowserView().tabItem { Label("Files", systemImage: "folder") }.tag(2)
            LogView().tabItem { Label("Logs", systemImage: "text.alignleft") }.tag(3)
        }
    }
}
