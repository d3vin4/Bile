import SwiftUI

struct AppsView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var showGroups = false

    var filteredApps: [AppEntry] {
        let q = search.lowercased()
        if q.isEmpty { return state.apps }
        var result: [AppEntry] = []
        for app in state.apps {
            if app.name.lowercased().contains(q) || app.bundleId.lowercased().contains(q) {
                result.append(app)
            }
        }
        return result
    }

    var body: some View {
        NavigationView {
            List {
                Section("Applications (\(state.apps.count))") {
                    ForEach(filteredApps) { app in
                        NavigationLink(destination: ContainerDetailView(app: app, isGroup: false)) {
                            AppRow(app: app)
                        }
                    }
                }
                Section("App Groups (\(state.groups.count))") {
                    ForEach(state.groups) { g in
                        NavigationLink {
                            ContainerDetailView(group: g)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(g.id).font(.headline)
                                Text(g.path).font(.caption2).foregroundStyle(.secondary)
                                Text("Owners: \(g.owners.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Apps & Groups")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { state.loadCatalog() } label: { Image(systemName: "arrow.clockwise") }
                }
            }
        }
    }
}

struct AppRow: View {
    let app: AppEntry
    var body: some View {
        VStack(alignment: .leading) {
            Text(app.name).font(.headline)
            Text(app.bundleId).font(.caption).foregroundStyle(.secondary)
            if !app.dataContainer.isEmpty {
                Text(app.dataContainer).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ContainerDetailView: View {
    @EnvironmentObject var state: AppState
    var app: AppEntry?
    var group: GroupEntry?

    init(app: AppEntry) { self.app = app; self.group = nil }
    init(group: GroupEntry) { self.app = nil; self.group = group }

    var containerPath: String { app?.dataContainer ?? group?.path ?? "" }
    var bundleId: String { app?.bundleId ?? "" }
    var name: String { app?.name ?? group?.id ?? "" }

    var body: some View {
        VStack {
            Text(containerPath).font(.caption2).foregroundStyle(.secondary).padding()
            Button("Open in Files") {
                state.openContainer(path: containerPath, bundleId: bundleId, name: name)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .navigationTitle(name)
    }
}
