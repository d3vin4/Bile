import SwiftUI
import Darwin

/// The Apps tab: every installed application as LaunchServices sees it.
///
/// Pure LaunchServices enumeration — no pairing, no tunnel, no escapes. Paths
/// are shown because they are useful once a sandbox escape exists; until then
/// opening another app's container simply reports iOS's denial.
struct AppsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager
    @StateObject private var catalog = AppCatalog()

    var body: some View {
        NavigationView {
            Group {
                if catalog.apps.isEmpty {
                    emptyState
                } else {
                    List(catalog.apps) { app in
                        AppRow(app: app)
                            .contextMenu { appMenu(app) }
                    }
                    .listStyle(.plain)
                    .refreshable { catalog.reload(state: state) }
                }
            }
            .searchable(text: $catalog.query, prompt: lang("search.apps"))
            .navigationTitle(lang("tab.apps"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { catalog.reload(state: state) } label: {
                        if catalog.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .onAppear { if catalog.apps.isEmpty { catalog.reload(state: state) } }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if catalog.isLoading {
                ProgressView()
            } else {
                Image(systemName: "app.badge")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(catalog.loadError ?? lang("apps.unavailable"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func appMenu(_ app: AppEntry) -> some View {
        Button {
            UIPasteboard.general.string = app.bundleId
            state.logLine("Copied bundle id \(app.bundleId)")
        } label: {
            Label(lang("copy.path"), systemImage: "doc.on.doc")
        }
        if !app.dataContainer.isEmpty {
            Button {
                AppState.shared.share(url: URL(fileURLWithPath: app.dataContainer))
            } label: {
                Label(lang("share"), systemImage: "square.and.arrow.up")
            }
        }
    }
}

// MARK: - Row

struct AppRow: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager
    let app: AppEntry
    @State private var showDenied = false

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(app: app, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.body).lineLimit(1)
                Text(app.bundleId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if !app.version.isEmpty {
                        Text("v\(app.version)")
                    }
                    if app.type == "system" {
                        Text("system")
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    if !app.dataContainer.isEmpty {
                        Label(app.isReadable ? "readable" : "locked",
                              systemImage: app.isReadable ? "checkmark.circle" : "lock")
                            .foregroundStyle(app.isReadable ? Color.green : Color.secondary)
                    }
                }
                .font(.caption2)
            }
            Spacer(minLength: 0)
            if !app.dataContainer.isEmpty {
                Button {
                    if app.isReadable {
                        AppState.shared.selectedTab = .files
                        NotificationCenter.default.post(
                            name: .openPathInFiles, object: app.dataContainer
                        )
                    } else {
                        showDenied = true
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.body)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
        .alert("Readipa", isPresented: $showDenied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lang("container.locked"))
        }
    }
}

extension Notification.Name {
    static let openPathInFiles = Notification.Name("readipa.openPathInFiles")
}

// MARK: - Icon

struct AppIcon: View {
    let app: AppEntry
    let size: CGFloat

    var body: some View {
        if let data = app.icon, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            let letter = String(app.name.prefix(1)).uppercased()
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: size, height: size)
                .overlay(
                    Text(letter).font(.headline).foregroundStyle(.white)
                )
        }
    }
}

// MARK: - Catalog

@MainActor
final class AppCatalog: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var isLoading = false
    @Published var loadError: String? = nil
    @Published var query = "" {
        didSet { applyFilter() }
    }
    private var all: [AppEntry] = []

    func reload(state: AppState) {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        Task.detached(priority: .userInitiated) {
            let apps = LaunchServicesApps.enumerate()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.all = apps
                self.applyFilter()
                self.isLoading = false
                state.logLine("LaunchServices: \(apps.count) apps")
                if apps.isEmpty {
                    self.loadError = LanguageManager.shared.t("apps.unavailable")
                }
            }
        }
    }

    private func applyFilter() {
        let q = query.lowercased()
        guard !q.isEmpty else {
            apps = all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return
        }
        apps = all.filter {
            $0.name.lowercased().contains(q) || $0.bundleId.lowercased().contains(q)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// LaunchServices enumeration via the ObjC runtime — the same interface
/// launchers use. Degrades gracefully when iOS refuses.
enum LaunchServicesApps {

    static func enumerate() -> [AppEntry] {
        guard
            let workspaceClass = NSClassFromString("LSApplicationWorkspace")
                as? NSObject.Type,
            let workspace = workspaceClass
                .perform(NSSelectorFromString("defaultWorkspace"))?
                .takeUnretainedValue()
        else { return [] }

        guard
            let raw = workspace.perform(NSSelectorFromString("allApplications"))?
                .takeUnretainedValue(),
            let proxies = raw as? [NSObject]
        else { return [] }

        var out: [AppEntry] = []
        for proxy in proxies {
            guard let bundleId = proxy.value(forKey: "applicationIdentifier") as? String,
                  !bundleId.isEmpty
            else { continue }
            let name = (proxy.value(forKey: "localizedName") as? String) ?? bundleId
            let version = (proxy.value(forKey: "shortVersionString") as? String) ?? ""
            let bundleURL = proxy.value(forKey: "bundleURL") as? URL
            let containerURL = proxy.value(forKey: "dataContainerURL") as? URL

            let type = isSystem(bundleURL) ? "system" : "user"
            out.append(AppEntry(
                bundleId: bundleId,
                name: name,
                version: version,
                type: type,
                bundlePath: bundleURL?.path ?? "",
                dataContainer: containerURL?.path ?? "",
                icon: iconData(bundleURL: bundleURL)
            ))
        }
        return out
    }

    /// Apps under /System/Library or /Applications with a system marker are
    /// reported as system; everything else counts as user-installed.
    private static func isSystem(_ bundleURL: URL?) -> Bool {
        guard let path = bundleURL?.path else { return false }
        return path.hasPrefix("/System/Library")
            || path.hasPrefix("/private/var/StagedSystemLibrary")
            || path.hasPrefix("/Applications/Cydia")
    }

    /// Reads the icon straight from the app bundle (CFBundleIcons) — plain
    /// file access, bundles are world-readable.
    private static func iconData(bundleURL: URL?) -> Data? {
        guard let bundleURL else { return nil }
        let infoPlist = bundleURL.appendingPathComponent("Info.plist")
        guard
            let raw = NSDictionary(contentsOfFile: infoPlist.path),
            let icons = raw["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String],
            let last = files.last
        else { return nil }
        // Prefer the @2x/@3x renditions when present.
        let candidates = [
            bundleURL.appendingPathComponent(last + "@3x.png").path,
            bundleURL.appendingPathComponent(last + "@2x.png").path,
            bundleURL.appendingPathComponent(last + ".png").path,
            bundleURL.appendingPathComponent(last).path,
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            if let data = FileManager.default.contents(atPath: c), !data.isEmpty {
                return data
            }
        }
        return nil
    }
}
