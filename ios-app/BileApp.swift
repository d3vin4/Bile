import SwiftUI

@main
struct BileApp: App {
    @StateObject private var state = AppState.shared
    @StateObject private var lang = LanguageManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(lang)
                .tint(.white)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager

    var body: some View {
        let tabs = TabView(selection: $state.selectedTab) {
            FilesView()
                .tabItem { Label(lang("tab.files"), systemImage: "folder") }
                .tag(AppTab.files)
            AppsView()
                .tabItem { Label(lang("tab.apps"), systemImage: "app.badge") }
                .tag(AppTab.apps)
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
}
