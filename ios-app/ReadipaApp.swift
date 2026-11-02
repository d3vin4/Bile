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
        let tabs = TabView {
            SetupView()
                .tabItem { Label("Setup", systemImage: "gear") }
            AppsView()
                .tabItem { Label("Apps", systemImage: "app.badge") }
            BrowserView()
                .tabItem { Label("Files", systemImage: "folder") }
            LogView()
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
        }

        if #available(iOS 26.0, *) {
            tabs.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            tabs
        }
    }
}
