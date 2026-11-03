import SwiftUI

struct AppsView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager
    @State private var search = ""
    @State private var mode: Int = 0

    private var filteredApps: [AppEntry] {
        let q = search.lowercased()
        guard !q.isEmpty else { return state.apps }
        var result: [AppEntry] = []
        for app in state.apps where app.name.lowercased().contains(q)
            || app.bundleId.lowercased().contains(q) {
            result.append(app)
        }
        return result
    }

    private var filteredGroups: [GroupEntry] {
        let q = search.lowercased()
        guard !q.isEmpty else { return state.groups }
        return state.groups.filter { group in
            group.id.lowercased().contains(q)
                || group.owners.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    Label(lang("tab.apps"), systemImage: "square.grid.2x2").tag(0)
                    Label("App Groups", systemImage: "square.stack.3d.up").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                if state.apps.isEmpty && state.groups.isEmpty {
                    emptyState
                } else if mode == 0 {
                    appList
                } else {
                    groupList
                }
            }
            .searchable(text: $search, prompt: mode == 0 ? lang("search.apps") : lang("search.groups"))
            .navigationTitle(mode == 0 ? lang("apps") : lang("app.groups"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { state.loadCatalog() } label: {
                        if state.isLoadingCatalog {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(!state.hasPairingFile || state.isLoadingCatalog)
                }
            }
        }
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(state.hasPairingFile ? "Tap ⟳ to load the catalog" : "Pair the device first (Setup tab)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Apps

    private var appList: some View {
        List(filteredApps) { app in
            NavigationLink(destination: AppDetailView(app: app)) {
                AppRow(app: app)
            }
        }
        .listStyle(.plain)
        .refreshable { state.loadCatalog() }
    }

    // MARK: - App Groups

    private var groupList: some View {
        List(filteredGroups) { group in
            GroupRow(group: group, ownerNames: ownerNames(for: group))
        }
        .listStyle(.plain)
        .refreshable { state.loadCatalog() }
    }

    private func ownerNames(for group: GroupEntry) -> [String] {
        group.owners.map { bundleId in
            state.apps.first(where: { $0.bundleId == bundleId })?.name ?? bundleId
        }
    }
}

// MARK: - Rows

struct AppAvatar: View {
    let name: String
    var body: some View {
        let letter = String(name.prefix(1)).uppercased()
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(
                colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(width: 36, height: 36)
            .overlay(
                Text(letter)
                    .font(.headline)
                    .foregroundStyle(.white)
            )
    }
}

struct AppRow: View {
    @EnvironmentObject var lang: LanguageManager
    let app: AppEntry
    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleId: app.bundleId, name: app.name, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name).font(.body).lineLimit(1)
                    if app.type.lowercased() == "system" {
                        Text("system")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(app.bundleId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    switch app.access {
                    case "full":
                        Label("full access", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    case "documents":
                        Label("documents", systemImage: "doc")
                            .foregroundStyle(.orange)
                    default:
                        Label("no access", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                    if !app.groupContainers.isEmpty {
                        Label("\(app.groupContainers.count)", systemImage: "square.stack.3d.up")
                    }
                    if !app.version.isEmpty {
                        Text("v\(app.version)")
                    }
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct GroupRow: View {
    @EnvironmentObject var lang: LanguageManager
    let group: GroupEntry
    let ownerNames: [String]
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Icons of the apps that own the group.
                HStack(spacing: -8) {
                    ForEach(Array(group.owners.prefix(3)), id: \.self) { owner in
                        AppIconView(
                            bundleId: owner,
                            name: state.apps.first(where: { $0.bundleId == owner })?.name ?? owner,
                            size: 28
                        )
                    }
                }
                Text(shortGroupName)
                    .font(.body.bold())
                    .lineLimit(1)
                Spacer()
                Button {
                    state.openContainer(
                        path: group.path,
                        bundleId: group.owners.first ?? "",
                        name: shortGroupName
                    )
                } label: {
                    Label(lang("open.in.files"), systemImage: "folder")
                        .font(.caption)
                }
                .readipaGlassButton()
            }

            Text(group.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if !ownerNames.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "app").font(.caption2)
                    Text(ownerNames.joined(separator: ", "))
                        .font(.caption2)
                        .lineLimit(2)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// `group.com.example.app` → `example.app` for a readable title.
    private var shortGroupName: String {
        var parts = group.id.split(separator: ".").map(String.init)
        if let first = parts.first, first.lowercased() == "group" {
            parts.removeFirst()
        }
        return parts.isEmpty ? group.id : parts.joined(separator: ".")
    }
}

// MARK: - Detail

struct AppDetailView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager
    let app: AppEntry

    var body: some View {
        Form {
            Section(lang("apps")) {
                HStack(spacing: 10) {
                    AppIconView(bundleId: app.bundleId, name: app.name, size: 52)
                    VStack(alignment: .leading) {
                        Text(app.name).font(.headline)
                        Text(app.bundleId).font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if !app.version.isEmpty {
                    HStack { Text(lang("version")); Spacer(); Text(app.version).foregroundStyle(.secondary) }
                }
                HStack { Text(lang("type")); Spacer(); Text(app.type).foregroundStyle(.secondary) }
            }

            Section(lang("data.container")) {
                if app.dataContainer.isEmpty {
                    Text(lang("no.container")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(app.dataContainer)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    Button {
                        state.openContainer(path: app.dataContainer, bundleId: app.bundleId, name: app.name)
                    } label: {
                        Label(lang("open.in.files"), systemImage: "folder")
                    }
                    .readipaGlassButton(prominent: true)
                }
            }

            if !app.groupContainers.isEmpty {
                Section(lang("app.groups")) {
                    ForEach(app.groupContainers.sorted(by: { $0.key < $1.key }), id: \.key) { key, path in
                        Button {
                            state.openContainer(path: path, bundleId: app.bundleId, name: key)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key).font(.caption.bold()).lineLimit(1)
                                Text(path).font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            Section {
                Text("Open a container, then use the ⤓ button in the Files tab to export it as a ZIP "
                     + "and save it to Files. Exports are read-only — nothing in the container is "
                     + "modified and symbolic links are recorded, not followed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
