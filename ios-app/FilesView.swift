import SwiftUI
import QuickLook

/// The Files tab: a full browser rooted at `/`.
///
/// Everything here is plain `FileManager` work — the app contains no sandbox
/// escape, so paths iOS refuses simply show "Permission denied" until a real
/// escape ships. The tab keeps the native system look with Liquid Glass
/// surfaces and a single app-wide white accent.
struct FilesView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var lang: LanguageManager
    @StateObject private var model = FilesModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                breadcrumbBar
                content
                footer
            }
            .background(Color.bileBackground.ignoresSafeArea())

            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $model.showGoTo) { GoToSheet(model: model) }
            .sheet(isPresented: $model.showInfo) {
                if let path = model.infoPath {
                    FileInfoView(path: path, model: model)
                }
            }
            .sheet(isPresented: $model.showEditor) {
                if let path = model.editorPath {
                    TextEditorView(path: path)
                }
            }
            .sheet(isPresented: $model.showQuickLook) {
                if let path = model.quickLookPath {
                    QuickLookView(url: URL(fileURLWithPath: path))
                }
            }
            .alert(model.alertTitle, isPresented: $model.showAlert) {
                TextField(model.alertPlaceholder, text: $model.alertText)
                Button(lang("cancel"), role: .cancel) {}
                Button(model.alertActionLabel) { model.alertAction() }
            } message: {
                Text(model.alertMessage)
            }
            .confirmationDialog(
                Text(model.confirmTitle),
                isPresented: $model.showConfirm,
                titleVisibility: .visible
            ) {
                Button(lang("delete.permanently"), role: .destructive) {
                    model.confirmAction()
                }
                Button(lang("cancel"), role: .cancel) {}
            } message: {
                Text(model.confirmMessage)
            }
            .onAppear { model.attach(state: state, lang: lang) }
            .onReceive(NotificationCenter.default.publisher(for: .openPathInFiles)) { note in
                if let target = note.object as? String {
                    state.selectedTab = .files
                    model.go(to: target)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Breadcrumb

    private var breadcrumbBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    crumb("/", label: "/", id: "/", proxy: proxy)
                    ForEach(Array(model.crumbs.enumerated()), id: \.offset) { _, segment in
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        crumb(segment.path,
                              label: segment.name,
                              id: segment.path,
                              proxy: proxy,
                              current: segment.path == model.path)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color.bileSurface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.bileSeparator).frame(height: 0.5)
            }
        }
    }

    private func crumb(_ path: String, label: String, id: String,
                       proxy: ScrollViewProxy, current: Bool = false) -> some View {
        Text(label)
            .font(.footnote.monospaced())
            .fontWeight(current ? .bold : .regular)
            .foregroundStyle(current ? Color.primary : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                current ? AnyShapeStyle(BileTheme.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 5)
            )
            .contentShape(Rectangle())
            .onTapGesture { model.go(to: path) }
            .id(id)
            .onAppear {
                if current { proxy.scrollTo(id, anchor: .trailing) }
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.inSearchResults {
            searchResultsList
        } else if model.viewMode == .grid {
            grid
        } else {
            list
        }
    }

    private var list: some View {
        List {
            ForEach(model.displayed) { entry in
                FileRow(entry: entry, selected: model.selection.contains(entry.path),
                        selecting: model.isSelecting)
                    .listRowBackground(BileTheme.rowBackground)
                    .contentShape(Rectangle())
                    .onTapGesture { model.tap(entry) }
                    .contextMenu { entryMenu(entry) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { model.reload() }
        .overlay { emptyOrError }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 12) {
                ForEach(model.displayed) { entry in
                    VStack(spacing: 4) {
                        FileGlyph(entry: entry, size: 46)
                            .frame(height: 52)
                        Text(entry.name)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(
                        model.selection.contains(entry.path)
                            ? AnyShapeStyle(BileTheme.tint.opacity(0.18))
                            : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { model.tap(entry) }
                    .contextMenu { entryMenu(entry) }
                }
            }
            .padding(10)
        }
        .refreshable { model.reload() }
        .overlay { emptyOrError }
    }

    private var searchResultsList: some View {
        List {
            Section {
                ForEach(model.searchResults, id: \.self) { path in
                    let name = (path as NSString).lastPathComponent
                    HStack(spacing: 8) {
                        FileGlyph(path: path, size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name).font(.callout).lineLimit(1)
                            Text(path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .listRowBackground(BileTheme.rowBackground)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let entry = FileEntry(entryForPath: path)
                        model.tap(entry)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                }
            } header: {
                HStack {
                    Text("\(model.searchResults.count) matches")
                        .foregroundStyle(BileTheme.textSecondary)
                    Spacer()
                    if model.isSearching { ProgressView() }
                    Button(lang("search.close")) { model.exitSearch() }
                        .font(.caption)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var emptyOrError: some View {
        if let error = model.error {
            VStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(BileTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.displayed.isEmpty && !model.isLoading {
            VStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(lang("empty.folder"))
                    .foregroundStyle(BileTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        Group {
            if model.isSelecting {
                selectionBar
            } else if model.clipboardActive {
                clipboardBar
            } else {
                statusBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.bileSurface)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.bileSeparator).frame(height: 0.5)
        }
    }

    private var statusBar: some View {
        HStack {
            Text("\(model.displayed.count) items")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if let search = model.activeSearchDescription {
                Text(search)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var clipboardBar: some View {
        HStack(spacing: 12) {
            Text("\(model.clipboard.paths.count) ready to \(model.clipboard.isCut ? "move" : "copy")")
                .font(.caption)
            Spacer()
            Button(lang("cancel")) { model.clearClipboard() }
            Button {
                model.paste()
            } label: {
                Label(lang("paste"), systemImage: model.clipboard.isCut ? "arrow.down.doc" : "doc.on.doc")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text(lang("n.selected").replacingOccurrences(of: "%d", with: "\(model.selection.count)"))
                .font(.caption.bold())
            Spacer(minLength: 0)
            actionButton("square.and.arrow.up", lang("share")) { model.shareSelection() }
            actionButton("doc.on.doc", lang("copy")) { model.copySelection(cut: false) }
            actionButton("scissors", lang("cut")) { model.copySelection(cut: true) }
            actionButton("doc.zipper", lang("compress")) { model.compressSelection() }
            Menu {
                Button { model.copyPathsSelection() } label: {
                    Label(lang("copy.path"), systemImage: "link")
                }
                Button { model.selectAllOrNone() } label: {
                    Label(lang("select.all"), systemImage: "checkmark.circle")
                }
                Divider()
                Button(role: .destructive) { model.confirmDeleteSelection() } label: {
                    Label(lang("delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 38, height: 34)
            }
            .buttonStyle(.bordered)
            Button(lang("done")) { model.exitSelection() }
                .font(.caption.bold())
        }
        .font(.body)
        .foregroundStyle(.primary)
    }

    private func actionButton(_ system: String, _ label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .frame(width: 38, height: 34)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    // MARK: - Menus

    @ViewBuilder
    private func entryMenu(_ entry: FileEntry) -> some View {
        if entry.isDir || entry.isLink {
            Button { model.open(entry) } label: { Label(lang("open"), systemImage: "folder") }
        }
        if !entry.isDir {
            Button { model.quickLook(entry) } label: {
                Label(lang("preview"), systemImage: "eye")
            }
        }
        if model.isPlistLike(entry) {
            Button { model.showPlist(entry) } label: {
                Label(lang("plist.viewer"), systemImage: "list.bullet.rectangle")
            }
        }
        Button { model.copyPath(entry) } label: {
            Label(lang("copy.path"), systemImage: "link")
        }
        if entry.isTextFile && !entry.isDir {
            Button { model.edit(entry) } label: {
                Label(lang("edit"), systemImage: "pencil")
            }
        }
        Button { model.showInfoFor(entry) } label: {
            Label(lang("info"), systemImage: "info.circle")
        }
        Button { model.beginRename(entry) } label: {
            Label(lang("rename"), systemImage: "pencil.line")
        }
        Button { model.duplicate(entry) } label: {
            Label(lang("duplicate"), systemImage: "plus.square.on.square")
        }
        Button { model.copyOne(entry, cut: false) } label: {
            Label(lang("copy"), systemImage: "doc.on.doc")
        }
        Button { model.copyOne(entry, cut: true) } label: {
            Label(lang("cut"), systemImage: "scissors")
        }
        if entry.name.lowercased().hasSuffix(".zip") {
            Button { model.extract(entry) } label: {
                Label(lang("extract"), systemImage: "arrow.down.doc")
            }
        }
        Button { model.compress(entry) } label: {
            Label(lang("compress"), systemImage: "doc.zipper")
        }
        Button { model.share(entry) } label: {
            Label(lang("share"), systemImage: "square.and.arrow.up")
        }
        Button { model.addFavorite(entry.path) } label: {
            Label(lang("favorite.add"), systemImage: "star")
        }
        Divider()
        Button(role: .destructive) { model.confirmDelete(entry) } label: {
            Label(lang("delete"), systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarLeading) {
            Button { model.back() } label: { Image(systemName: "chevron.backward") }
                .disabled(!model.canGoBack)
            Button { model.forward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!model.canGoForward)
            Button { model.up() } label: { Image(systemName: "arrow.up") }
                .disabled(model.path == "/")
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { model.enterSearch() } label: { Image(systemName: "magnifyingglass") }
            Button { model.showGoTo = true } label: { Image(systemName: "location") }
            Menu {
                Button { model.toggleHidden() } label: {
                    Label(
                        model.showHidden ? lang("hide.hidden") : lang("show.hidden"),
                        systemImage: model.showHidden ? "eye.slash" : "eye"
                    )
                }
                Menu {
                    ForEach(SortOrder.allCases) { order in
                        Button { model.setSort(order) } label: {
                            if model.sort == order {
                                Label(lang(order.labelKey), systemImage: "checkmark")
                            } else {
                                Text(lang(order.labelKey))
                            }
                        }
                    }
                } label: {
                    Label(lang("sort"), systemImage: "arrow.up.arrow.down")
                }
                Button { model.toggleViewMode() } label: {
                    Label(
                        model.viewMode == .list ? lang("grid.view") : lang("list.view"),
                        systemImage: model.viewMode == .list ? "square.grid.2x2" : "list.bullet"
                    )
                }
                Divider()
                Button { model.newFolder() } label: {
                    Label(lang("new.folder"), systemImage: "folder.badge.plus")
                }
                Button { model.newFile() } label: {
                    Label(lang("new.file"), systemImage: "doc.badge.plus")
                }
                Button { model.createSymlinkHere() } label: {
                    Label(lang("new.symlink"), systemImage: "link.badge.plus")
                }
                Divider()
                Menu {
                    ForEach(model.favorites, id: \.self) { fav in
                        Button { model.go(to: fav) } label: {
                            Text((fav as NSString).lastPathComponent.isEmpty ? fav : (fav as NSString).lastPathComponent)
                        }
                    }
                    if model.favorites.isEmpty {
                        Text(lang("no.favorites"))
                    }
                } label: {
                    Label(lang("favorites"), systemImage: "star")
                }
                Button { model.addFavorite(model.path) } label: {
                    Label(lang("favorite.add"), systemImage: "star.badge.plus")
                }
                Divider()
                Button(role: .destructive) { model.enterSelection() } label: {
                    Label(lang("select"), systemImage: "checkmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Row views

struct FileRow: View {
    let entry: FileEntry
    let selected: Bool
    let selecting: Bool

    var body: some View {
        HStack(spacing: 10) {
            if selecting {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? BileTheme.tint : Color.secondary)
            }
            FileGlyph(entry: entry, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if entry.isLink, let target = entry.linkTarget {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.caption2)
                        Text(target)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if entry.isDir {
                        Text("directory")
                    } else {
                        Text(FileEntry.prettySize(entry.size))
                    }
                    Text("·")
                    Text(entry.modified.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(entry.permissionsString)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
    }
}

/// Stock SF Symbol glyph — nothing hand-drawn, tinted by type.

struct FileGlyph: View {
    var entry: FileEntry?
    var path: String = ""
    let size: CGFloat

    init(entry: FileEntry, size: CGFloat) {
        self.entry = entry
        self.size = size
    }

    /// Convenience when only a path is known (search results).
    init(path: String, size: CGFloat) {
        self.path = path
        self.size = size
        let a = LocalFS.attrs(at: path)
        self.entry = a.map {
            FileEntry(
                path: path,
                name: (path as NSString).lastPathComponent,
                isDir: $0.isDir,
                isLink: $0.isLink,
                size: $0.size,
                modified: $0.modified,
                permissions: $0.permissions,
                linkTarget: $0.linkTarget
            )
        }
    }

    var body: some View {
        let isLink = entry?.isLink ?? false
        Image(systemName: entry?.icon ?? "doc")
            .font(.system(size: size * 0.85, weight: .regular))
            .foregroundStyle(Self.tint(for: entry))
            .frame(width: size + 10, height: size + 10)
            .overlay(alignment: .bottomTrailing) {
                if isLink {
                    Image(systemName: "link.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .offset(x: 3, y: 3)
                }
            }
    }

    /// One unified, monochrome palette — every glyph reads in white on the
    /// dark gray canvas.
    static func tint(for entry: FileEntry?) -> Color {
        BileTheme.tint
    }
}
