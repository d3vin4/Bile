import SwiftUI
import AirliftFFI

@main
struct ReadipaApp: App {
    @StateObject private var state = AppState.shared
    @StateObject private var pairing = PairingController.shared

    init() {
        _ = al_log_init({ (_: UnsafeMutableRawPointer?, msg: UnsafePointer<CChar>?) in
            if let msg = msg {
                let line = String(cString: msg)
                DispatchQueue.main.async { AppState.shared.logLine(line) }
            }
        }, nil)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(pairing)
                .task {
                    // Restore credentials from the Keychain before reporting
                    // "not paired" — a relaunch must never lose the pairing.
                    _ = PairingController.restorePairingIfNeeded()
                    state.refreshPairingFile()
                    state.liveActivitiesEnabled = PairingController.liveActivitiesEnabled
                    state.logLine("Readipa ready — pairing file: \(state.hasPairingFile ? "found" : "missing")")
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let tabs = TabView(selection: $state.selectedTab) {
            SetupView()
                .tabItem { Label("Setup", systemImage: "gear") }
                .tag(AppTab.setup)
            AppsView()
                .tabItem { Label("Apps", systemImage: "app.badge") }
                .tag(AppTab.apps)
            BrowserView()
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(AppTab.files)
            LogView()
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
                .tag(AppTab.logs)
        }

        // One share sheet for the whole app: presenting it per-tab makes SwiftUI
        // complain when two tabs share the same binding.
        let withShare = tabs.sheet(isPresented: $state.showShareSheet) {
            if let url = state.exportedFileURL {
                ShareSheet(items: [url])
            }
        }

        if #available(iOS 26.0, *) {
            withShare.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            withShare
        }
    }
}
