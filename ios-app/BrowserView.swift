import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BrowserView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showImporter = false
    @State private var renameTarget: FileEntry? = nil
    @State private var renameName = ""
    @State private var showRename = false
    @State private var deleteTarget: FileEntry? = nil
    @State private var showDeleteConfirm = false
    @State private var replaceTarget: FileEntry? = nil
    @State private var showReplace = false

    var body: some View {
        NavigationView {
            Group {
                if state.selectedContainer == nil {
                    emptyState
                } else {
                    browser
                }
            }
            .navigationTitle(state.selectedContainer == nil ? "Files" : state.currentPathDisplay)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showNewFolder) { newFolderSheet }
            .sheet(isPresented: $showRename) { renameSheet }
            .sheet(isPresented: $state.showPreview) { previewSheet }
            .sheet(isPresented: $state.showDiagnosis) { diagnosisSheet }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { state.importFiles(from: urls) }
            }
            .fileImporter(isPresented: $showReplace, allowedContentTypes: [.data]) { result in
                if case .success(let url) = result, let target = replaceTarget {
                    state.replaceFile(target, with: url)
                }
                replaceTarget = nil
            }
            .confirmationDialog(
                deleteTarget.map { "Delete “\($0.name)”?" } ?? "Delete?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let t = deleteTarget { state.deleteEntry(t) }
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: {
                Text(deleteTarget?.isDir == true
                     ? "This folder and everything inside it will be deleted."
                     : "This file will be deleted.")
            }
        }
    }

    /// Each folder on the path, for the breadcrumb menu.
    private var breadcrumbLevels: [(title: String, path: String)] {
        var levels: [(title: String, path: String)] = []
        var accumulated: [String] = []
        for part in state.currentRelPath.split(separator: "/").map(String.init) {
            accumulated.append(part)
            levels.append((title: part, path: accumulated.joined(separator: "/")))
        }
        return levels
    }

    // MARK: - Pieces

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(lang("open.container.first"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var browser: some View {
        VStack(spacing: 8) {
            modeBanner
            content
        }
    }

    @ViewBuilder
    private var modeBanner: some View {
        if state.bridgeRequiresRiskyMoves && !state.allowRiskyMoves {
            banner(
                state.bridgeMode == "bridge_readonly"
                    ? "Folder listing needs “Allow risky moves” in Setup. Direct reads already work, "
                      + "so Save and ZIP export never touch the app."
                    : "This container blocks direct access. Enable “Allow risky moves” in Setup to list it "
                      + "(the folder is moved to Media temporarily).",
                color: .orange
            )
        } else if state.bridgeMode == "bridge_move" {
            banner(
                "AirLift mode: each operation moves the file through Media and back (15–30 s). "
                + "Every step is verified — if one cannot finish you will see exactly where the file is kept.",
                color: .secondary
            )
        } else if state.isExporting {
            HStack(spacing: 8) {
                ProgressView()
                Text("Exporting container to ZIP…").font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .readipaGlassCapsule()
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
            Text(text).font(.caption2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .readipaGlassCard(cornerRadius: 12)
        .padding(.horizontal, 12)
    }

    private var content: some View {
        List {
            if state.isLoadingFiles {
                HStack { ProgressView(); Text(lang("loading")).font(.caption).foregroundStyle(.secondary) }
            }
            if let e = state.filesError {
                Text(e)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ForEach(state.sortedEntries) { entry in
                row(entry)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $state.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: lang("filter.this.folder"))
        .refreshable { state.loadFiles() }
        .overlay {
            if !state.isLoadingFiles && state.sortedEntries.isEmpty && state.filesError == nil {
                Text(state.searchText.isEmpty ? lang("empty.folder") : lang("no.match"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ entry: FileEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.iconName)
                .foregroundStyle(entry.isDir ? Color.accentColor : (entry.isLink ? Color.orange : Color.secondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1)
                HStack(spacing: 6) {
                    if !entry.isDir { Text(FileEntry.prettySize(entry.size)) }
                    if entry.isLink { Text("symlink") }
                    if !entry.modified.isEmpty && entry.modified != "1970-01-01 00:00:00" {
                        Text(entry.modified.prefix(16))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.isDir {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDir { state.navigate(into: entry.name) } else { state.preview(entry) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleteTarget = entry
                showDeleteConfirm = true
            } label: { Label(lang("delete"), systemImage: "trash") }

            Button {
                renameTarget = entry
                renameName = entry.name
                showRename = true
            } label: { Label("Rename", systemImage: "pencil") }
            .tint(.blue)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if !entry.isDir {
                Button {
                    state.shareFile(entry)
                } label: { Label(lang("save"), systemImage: "square.and.arrow.up") }
                .tint(.green)
            }
        }
        .contextMenu {
            if !entry.isDir {
                Button { state.preview(entry) } label: {
                    Label(lang("preview"), systemImage: "doc.text.magnifyingglass")
                }
                Button { state.shareFile(entry) } label: {
                    Label(lang("save"), systemImage: "square.and.arrow.up")
                }
                Button {
                    replaceTarget = entry
                    showReplace = true
                } label: {
                    Label(lang("replace"), systemImage: "arrow.triangle.2.circlepath")
                }
            } else {
                Button { state.navigate(into: entry.name) } label: {
                    Label(lang("open"), systemImage: "folder")
                }
                Button { state.exportFolderZip(entry) } label: {
                    Label(lang("export.as.zip"), systemImage: "square.and.arrow.down.on.square")
                }
            }

            Divider()

            Button {
                renameTarget = entry
                renameName = entry.name
                showRename = true
            } label: {
                Label(lang("rename.or.move"), systemImage: "pencil")
            }

            Button {
                UIPasteboard.general.string = state.absolutePath(for: entry)
                state.logLine("Copied path: \(state.absolutePath(for: entry))")
            } label: {
                Label(lang("copy.path"), systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                deleteTarget = entry
                showDeleteConfirm = true
            } label: {
                Label(lang("delete"), systemImage: "trash")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if state.selectedContainer != nil {
                HStack(spacing: 14) {
                    Button {
                        state.navigateBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!state.canGoBack)

                    Button {
                        state.navigateHome()
                    } label: {
                        Image(systemName: "house")
                    }
                    .disabled(state.currentRelPath.isEmpty)
                }
            }
        }
        ToolbarItem(placement: .principal) {
            if state.selectedContainer != nil {
                Menu {
                    Button(lang("container.root")) { state.navigateHome() }
                    ForEach(breadcrumbLevels, id: \.path) { level in
                        Button(level.title) { state.jump(to: level.path) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(state.breadcrumb())
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
            }
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            if state.selectedContainer != nil {
                Menu {
                    Picker("Sort", selection: $state.sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(lang(order.rawValue.lowercased().replacingOccurrences(of: " ", with: "."))).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                Button { state.exportContainerAsZip() } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
                .disabled(state.isExporting)
                Button { state.diagnose() } label: {
                    if state.isDiagnosing {
                        ProgressView()
                    } else {
                        Image(systemName: "stethoscope")
                    }
                }
                .disabled(state.isDiagnosing)
                Button { showNewFolder = true } label: { Image(systemName: "folder.badge.plus") }
                Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
            }
        }
    }

    private var newFolderSheet: some View {
        NavigationView {
            Form {
                TextField(lang("folder.name"), text: $newFolderName)
                Button(lang("create")) {
                    if !newFolderName.isEmpty { state.createFolder(name: newFolderName) }
                    newFolderName = ""
                    showNewFolder = false
                }
                .disabled(newFolderName.isEmpty)
            }
            .navigationTitle("New folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang("cancel")) { showNewFolder = false }
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private var renameSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField(lang("new.name"), text: $renameName)
                        .autocapitalization(.none)
                } footer: {
                    Text("A name only renames. To move the item, include a path relative to this "
                         + "folder, e.g. Library/Preferences/newname.plist. Readipa refuses to "
                         + "overwrite an existing item.")
                    .font(.caption2)
                }
                Button(lang("apply")) {
                    if let t = renameTarget, !renameName.isEmpty {
                        state.renameEntry(t, to: renameName)
                    }
                    showRename = false
                }
                .disabled(renameName.isEmpty)
            }
            .navigationTitle(lang("rename.or.move"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang("cancel")) { showRename = false }
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private var diagnosisSheet: some View {
        NavigationView {
            ScrollView {
                Text(state.diagnosisText ?? "")
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Diagnosis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lang("done")) { state.showDiagnosis = false }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { state.shareDiagnosis() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var previewSheet: some View {
        NavigationView {
            ScrollView {
                Text(state.previewText ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(state.previewName ?? "Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(lang("done")) { state.showPreview = false }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if let name = state.previewName,
                           let entry = state.entries.first(where: { $0.name == name }) {
                            state.showPreview = false
                            state.shareFile(entry)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}
