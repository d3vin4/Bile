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
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager
    @State private var gateRemaining = 5
    @State private var gatePassed = false

    var body: some View {
        if gatePassed {
            mainTabs
        } else {
            launchGate
        }
    }

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
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(.orange)
            Text("Readipa")
                .font(.largeTitle.bold())
            Text("Important notice")
                .font(.title3.bold())
            Text("Readipa is a native file manager for Application Containers and App Groups.\n\n"
                 + "It only operates inside /var/mobile/Containers/Data/Application and "
                 + "/var/mobile/Containers/Shared/AppGroup. It never deletes anything outside "
                 + "those roots and never follows symbolic links while cleaning up.\n\n"
                 + "Pairing, exports and risky moves are verified step by step; if an operation "
                 + "cannot finish you will always be told exactly where your data is kept.\n\n"
                 + "Only use this app on devices you own and apps you are authorised to inspect.")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Text("Entering in \(gateRemaining)s")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.orange)

            Button("I understand") { gatePassed = true }
                .readipaGlassButton(prominent: true)
                .disabled(gateRemaining > 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .task {
            for remaining in (1...5).reversed() {
                gateRemaining = remaining
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            gateRemaining = 0
            gatePassed = true
        }
    }
}
