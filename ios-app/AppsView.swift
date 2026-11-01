import SwiftUI

struct AppsView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""

    var filteredApps: [AppEntry] {
        let q = search.lowercased()
        if q.isEmpty { return state.apps }
        var result: [AppEntry] = []
        for app in state.apps {
            let nameMatch = app.name.lowercased().contains(q)
            let bundleMatch = app.bundleId.lowercased().contains(q)
            if nameMatch || bundleMatch {
                result.append(app)
            }
        }
        return result
    }

    var body: some View {
        NavigationView {
            AppsListView(apps: filteredApps, groups: state.groups)
                .searchable(text: $search)
                .navigationTitle("Apps & Groups")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: { state.loadCatalog() }) {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
        }
    }
}

struct AppsListView: View {
    let apps: [AppEntry]
    let groups: [GroupEntry]
    var body: some View {
        List {
            Section(header: Text("Applications")) {
                ForEach(apps) { app in
                    NavigationLink(destination: ContainerDetailView(app: app)) {
                        AppRow(app: app)
                    }
                }
            }
            Section(header: Text("App Groups")) {
                ForEach(groups) { g in
                    NavigationLink(destination: ContainerDetailView(group: g)) {
                        GroupRow(group: g)
                    }
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

struct GroupRow: View {
    let group: GroupEntry
    var body: some View {
        VStack(alignment: .leading) {
            Text(group.id).font(.headline)
            Text(group.path).font(.caption2).foregroundStyle(.secondary)
            Text("Owners: " + group.owners.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
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
