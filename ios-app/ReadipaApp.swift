import SwiftUI
import AirliftFFI

@main
struct ReadipaApp: App {
    @StateObject private var state = AppState.shared
    @StateObject private var pairing = PairingController.shared
    @StateObject private var lang = LanguageManager.shared

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
                .environmentObject(lang)
                .task {
                    _ = PairingController.restorePairingIfNeeded()
                    state.refreshPairingFile()
                    state.liveActivitiesEnabled = PairingController.liveActivitiesEnabled
                    state.logLine("Readipa ready — pairing file: \(state.hasPairingFile ? "found" : "missing")")
                    state.startupMaintenance()
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager
    @State private var gatePassed = UserDefaults.standard.bool(forKey: LaunchGateView.skipKey)

    var body: some View {
        if gatePassed {
            mainTabs
        } else {
            launchGate
        }
    }

    @ViewBuilder
    private var mainTabs: some View {
        let tabs = TabView(selection: $state.selectedTab) {
            SetupView()
                .tabItem { Label(lang("tab.setup"), systemImage: "gear") }
                .tag(AppTab.setup)
            AppsView()
                .tabItem { Label(lang("tab.apps"), systemImage: "app.badge") }
                .tag(AppTab.apps)
            BrowserView()
                .tabItem { Label(lang("tab.files"), systemImage: "folder") }
                .tag(AppTab.files)
            LogView()
                .tabItem { Label(lang("tab.logs"), systemImage: "text.alignleft") }
                .tag(AppTab.logs)
        }

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

    private var launchGate: some View {
        LaunchGateView {
            withAnimation { gatePassed = true }
        }
    }
}
