import SwiftUI

struct AppsView: View {
    @EnvironmentObject var state: AppState
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
                    Label("Apps", systemImage: "square.grid.2x2").tag(0)
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
            .searchable(text: $search, prompt: mode == 0 ? "Search apps or bundle id" : "Search groups or owner")
            .navigationTitle(mode == 0 ? "Apps" : "App Groups")
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
    let app: AppEntry
    var body: some View {
        HStack(spacing: 10) {
            AppAvatar(name: app.name)
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
                HStack(spacing: 6) {
                    if !app.dataContainer.isEmpty {
                        Label("container", systemImage: "folder")
                    }
                    if !app.groupContainers.isEmpty {
                        Label("\(app.groupContainers.count) group\(app.groupContainers.count == 1 ? "" : "s")",
                              systemImage: "square.stack.3d.up")
                    }
                    if !app.version.isEmpty {
                        Text("v\(app.version)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct GroupRow: View {
    let group: GroupEntry
    let ownerNames: [String]
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(Color.accentColor)
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
                    Label("Open", systemImage: "folder")
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
    let app: AppEntry

    var body: some View {
        Form {
            Section("Application") {
                HStack(spacing: 10) {
                    AppAvatar(name: app.name)
                    VStack(alignment: .leading) {
                        Text(app.name).font(.headline)
                        Text(app.bundleId).font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if !app.version.isEmpty {
                    HStack { Text("Version"); Spacer(); Text(app.version).foregroundStyle(.secondary) }
                }
                HStack { Text("Type"); Spacer(); Text(app.type).foregroundStyle(.secondary) }
            }

            Section("Data Container") {
                if app.dataContainer.isEmpty {
                    Text("This app has no data container").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(app.dataContainer)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    Button {
                        state.openContainer(path: app.dataContainer, bundleId: app.bundleId, name: app.name)
                    } label: {
                        Label("Open in Files", systemImage: "folder")
                    }
                    .readipaGlassButton(prominent: true)
                }
            }

            if !app.groupContainers.isEmpty {
                Section("App Groups") {
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
