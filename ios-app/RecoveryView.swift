import SwiftUI

/// Everything Readipa ever moved out of a container lives here. Nothing is
/// deleted automatically: empty items can be swept in one tap, anything with
/// data is listed until you decide what to do with it.
struct RecoveryView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager

    @State private var restoreTarget: LeftoverEntry? = nil
    @State private var showRestore = false
    @State private var deleteTarget: LeftoverEntry? = nil
    @State private var showDelete = false
    @State private var showCleanup = false
    @State private var destinationFolder = ""
    @State private var customFolder = ""

    private var safeCount: Int { state.leftovers.filter(\.safeToRemove).count }
    private var dataCount: Int { state.leftovers.count - safeCount }

    private var groups: [(kind: String, items: [LeftoverEntry])] {
        Dictionary(grouping: state.leftovers, by: \.kind)
            .map { (kind: $0.key, items: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.kind < $1.kind }
    }

    var body: some View {
        List {
            summarySection
            if state.leftovers.isEmpty {
                emptySection
            } else {
                ForEach(groups, id: \.kind) { group in
                    Section {
                        ForEach(group.items) { item in
                            row(item)
                        }
                    } header: {
                        HStack {
                            Text(group.kind)
                            Spacer()
                            Text("\(group.items.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            helpSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(lang("recovery"))
        .refreshable { state.scanLeftovers() }
        .onAppear { state.scanLeftovers() }
        .sheet(isPresented: $showRestore) { restoreSheet }
        .confirmationDialog(
            "Delete “\(deleteTarget?.name ?? "")”?",
            isPresented: $showDelete,
            titleVisibility: .visible
        ) {
            Button(lang("delete.permanently"), role: .destructive) {
                if let t = deleteTarget { state.deleteLeftover(t) }
                deleteTarget = nil
            }
            Button(lang("cancel"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.safeToRemove == true
                 ? lang("delete.leftover.safe")
                 : lang("delete.leftover.warning"))
        }
        .confirmationDialog(
            "\(lang("clean.empty")) (\(safeCount))?",
            isPresented: $showCleanup,
            titleVisibility: .visible
        ) {
            Button("\(lang("clean.empty")) \(safeCount)", role: .destructive) {
                state.cleanupLeftovers()
            }
            Button(lang("cancel"), role: .cancel) {}
        } message: {
            Text("Only bridge links and empty folders are removed. Anything that still "
                 + "contains files stays listed.")
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            HStack(spacing: 8) {
                StatusChip(title: lang("total"), value: "\(state.leftovers.count)", ok: state.leftovers.isEmpty)
                StatusChip(title: lang("empty.count"), value: "\(safeCount)", ok: true)
                StatusChip(title: lang("with.data"), value: "\(dataCount)", ok: dataCount == 0)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

            Button {
                state.scanLeftovers()
            } label: {
                Label(lang("scan"), systemImage: "arrow.clockwise")
            }
            .disabled(!state.hasPairingFile)

            if safeCount > 0 {
                Button {
                    showCleanup = true
                } label: {
                    Label("\(lang("clean.empty")) (\(safeCount))", systemImage: "sparkles")
                }
                .foregroundStyle(.orange)
            }

            if state.needsRecoveryCheck {
                Label("A previous operation may have been interrupted — restore anything listed below.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                Text(lang("nothing.to.recover"))
                    .font(.callout)
                Text("Every container is exactly where it should be.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private var helpSection: some View {
        Section {
            Text("These are temporary items Readipa created in /var/mobile/Media. "
                 + "Bridge links and empty staging folders hold no data and can be swept "
                 + "safely. Anything that still contains files is kept until you decide — "
                 + "you can put it back into a container or save a copy to Files.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text(lang("how.works"))
        }
    }

    // MARK: - Row

    private func row(_ item: LeftoverEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isLink ? "link" : (item.isDir ? "folder" : "doc"))
                .foregroundStyle(item.safeToRemove ? Color.secondary : Color.orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(item.explain) · \(FileEntry.prettySize(item.size))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button {
                    restoreTarget = item
                    destinationFolder = ""
                    customFolder = ""
                    showRestore = true
                } label: {
                    Label(lang("restore.into"), systemImage: "arrow.uturn.backward")
                }
                Button {
                    state.saveLeftoverCopy(item)
                } label: {
                    Label(lang("save") + "…", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    deleteTarget = item
                    showDelete = true
                } label: {
                    Label(lang("delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Restore sheet

    private var restoreSheet: some View {
        NavigationView {
            Form {
                Section(lang("leftover")) {
                    Text(restoreTarget?.name ?? "")
                        .font(.caption.monospaced())
                    Text(restoreTarget?.explain ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let container = state.selectedContainer {
                    Section {
                        Text(container.name).font(.caption)
                        Picker(lang("folder"), selection: $destinationFolder) {
                            Text("/ (container root)").tag("")
                            ForEach(state.folderChoices.filter { !$0.isEmpty }, id: \.self) { folder in
                                Text(folder).tag(folder)
                            }
                        }
                        TextField(lang("destination.folder"), text: $customFolder)
                            .autocapitalization(.none)
                            .font(.caption.monospaced())
                    } header: {
                        Text(lang("restore.into"))
                    } footer: {
                        Text("Pick a folder from the container you are browsing, or type a path "
                             + "manually. Readipa refuses to overwrite an existing item.")
                        .font(.caption2)
                    }
                } else {
                    Section {
                        Label("Open the destination container in the Apps tab first.",
                              systemImage: "folder.badge.questionmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Button(lang("restore")) {
                        if let item = restoreTarget {
                            let folder = customFolder.isEmpty ? destinationFolder : customFolder
                            state.recoverLeftover(item, intoFolder: folder)
                        }
                        showRestore = false
                    }
                    .disabled(state.selectedContainer == nil)
                    Button(lang("cancel")) { showRestore = false }
                }
            }
            .navigationTitle(lang("restore.leftover"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
