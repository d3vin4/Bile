import SwiftUI
import Combine

/// State + operations for the Files tab. All heavy lifting runs off the main
/// actor; results land back on `@MainActor` published properties.
@MainActor
final class FilesModel: ObservableObject {

    // MARK: - Navigation

    @Published var path: String = "/"
    @Published var items: [FileEntry] = []
    @Published private(set) var history: [String] = []
    @Published private(set) var forwardStack: [String] = []
    @Published var isLoading = false
    @Published var error: String? = nil

    // MARK: - View options (persisted)

    @Published var showHidden: Bool = UserDefaults.standard.bool(forKey: "fs.showHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "fs.showHidden"); reload() }
    }
    @Published var sort: SortOrder = SortOrder(
        rawValue: UserDefaults.standard.string(forKey: "fs.sort") ?? ""
    ) ?? .nameAscending {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "fs.sort") }
    }
    @Published var viewModeRaw: String = UserDefaults.standard.string(forKey: "fs.viewMode") ?? "list" {
        didSet { UserDefaults.standard.set(viewModeRaw, forKey: "fs.viewMode") }
    }
    var viewMode: ViewMode { ViewMode(rawValue: viewModeRaw) ?? .list }

    // MARK: - Selection & clipboard

    @Published var isSelecting = false
    @Published var selection: Set<String> = []
    @Published var clipboard = FSClipboard(paths: [], isCut: false)
    var clipboardActive: Bool { !clipboard.isEmpty }

    // MARK: - Sheets

    @Published var showGoTo = false
    @Published var showInfo = false
    @Published var infoPath: String? = nil
    @Published var showEditor = false
    @Published var editorPath: String? = nil
    @Published var showQuickLook = false
    @Published var quickLookPath: String? = nil

    // MARK: - Alerts & confirms

    @Published var showAlert = false
    @Published var alertTitle = ""
    @Published var alertMessage = ""
    @Published var alertPlaceholder = ""
    @Published var alertText = ""
    @Published var alertActionLabel = "OK"
    @Published var showConfirm = false
    @Published var confirmTitle = ""
    @Published var confirmMessage = ""

    private enum AlertKind {
        case newFolder, newFile, rename(String), goTo, symlink
    }
    private var alertKind: AlertKind = .newFolder

    private enum ConfirmKind {
        case deleteOne(String), deleteSelection
    }
    private var confirmKind: ConfirmKind = .deleteOne("")

    // MARK: - Search

    @Published var inSearchResults = false
    @Published var searchResults: [String] = []
    @Published var isSearching = false
    @Published var activeSearchDescription: String? = nil
    private var searchTask: Task<Void, Never>? = nil

    // MARK: - Favorites

    @Published var favorites: [String] =
        UserDefaults.standard.stringArray(forKey: "fs.favorites") ?? ["/"] {
        didSet { UserDefaults.standard.set(favorites, forKey: "fs.favorites") }
    }

    // MARK: - Environment

    private unowned var state: AppState! = nil
    private unowned var lang: LanguageManager! = nil

    func attach(state: AppState, lang: LanguageManager) {
        if self.state == nil { self.state = state }
        if self.lang == nil { self.lang = lang }
        if items.isEmpty && !isLoading { reload() }
    }

    private func t(_ key: String) -> String { lang?.t(key) ?? key }
    private func note(_ s: String) { state?.logLine(s) }

    // MARK: - Derived

    var title: String {
        path == "/" ? "/" : (path as NSString).lastPathComponent
    }

    var crumbs: [(name: String, path: String)] {
        var parts = path.split(separator: "/").map(String.init)
        var out: [(String, String)] = []
        var acc = ""
        for p in parts {
            acc += "/" + p
            out.append((p, acc))
        }
        parts.removeAll()
        return out
    }

    var displayed: [FileEntry] {
        func key(_ e: FileEntry) -> Bool { e.isDir }
        let base = items
        let sorted: [FileEntry]
        switch sort {
        case .nameAscending:
            sorted = base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            sorted = base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .sizeDescending:
            sorted = base.sorted { $0.size > $1.size }
        case .sizeAscending:
            sorted = base.sorted { $0.size < $1.size }
        case .dateNewest:
            sorted = base.sorted { $0.modified > $1.modified }
        case .dateOldest:
            sorted = base.sorted { $0.modified < $1.modified }
        }
        return sorted.sorted { a, b in
            if key(a) != key(b) { return key(a) }
            return false
        }
    }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    // MARK: - Navigation

    func reload() {
        let target = path
        isLoading = true
        error = nil
        let hidden = showHidden
        Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [FileEntry] = []
            var failure: String? = nil
            do {
                entries = try LocalFS.list(target, showHidden: hidden)
            } catch {
                failure = Self.permissionMessage(for: target, error: error)
            }
            await MainActor.run { [weak self] in
                guard let self, self.path == target else { return }
                self.items = entries
                self.error = failure
                self.isLoading = false
                if let failure { self.note("ls \(target): \(failure)") }
            }
        }
    }

    static func permissionMessage(for path: String, error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == 257 {
            return "Permission denied — iOS only opens this with a sandbox escape"
        }
        return ns.localizedDescription
    }

    func go(to target: String) {
        let clean = normalize(target)
        guard clean != path else { return }
        history.append(path)
        forwardStack.removeAll()
        path = clean
        exitSearch()
        reload()
    }

    func open(_ entry: FileEntry) {
        if entry.isDir {
            go(to: entry.path)
        } else if entry.isTextFile {
            edit(entry)
        } else {
            quickLook(entry)
        }
    }

    func tap(_ entry: FileEntry) {
        if isSelecting {
            if selection.contains(entry.path) {
                selection.remove(entry.path)
            } else {
                selection.insert(entry.path)
            }
        } else {
            open(entry)
        }
    }

    func back() {
        guard let prev = history.popLast() else { return }
        forwardStack.append(path)
        path = prev
        exitSearch()
        reload()
    }

    func forward() {
        guard let next = forwardStack.popLast() else { return }
        history.append(path)
        path = next
        exitSearch()
        reload()
    }

    func up() {
        guard path != "/" else { return }
        go(to: (path as NSString).deletingLastPathComponent.isEmpty
            ? "/" : (path as NSString).deletingLastPathComponent)
    }

    private func normalize(_ p: String) -> String {
        var p = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { return "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        // Collapse "a/./b" and "a/b/../c" without touching the filesystem.
        var stack: [String] = []
        for comp in p.split(separator: "/") {
            switch comp {
            case ".", "": continue
            case "..": _ = stack.popLast()
            default: stack.append(String(comp))
            }
        }
        return "/" + stack.joined(separator: "/")
    }

    // MARK: - View options

    func toggleHidden() { showHidden.toggle() }
    func setSort(_ order: SortOrder) { sort = order; reload() }
    func toggleViewMode() { viewModeRaw = viewMode == .list ? "grid" : "list" }

    // MARK: - Selection

    func enterSelection() { isSelecting = true; selection.removeAll() }
    func exitSelection() { isSelecting = false; selection.removeAll() }
    func selectAllOrNone() {
        if selection.count == displayed.count {
            selection.removeAll()
        } else {
            selection = Set(displayed.map(\.path))
        }
    }

    // MARK: - Clipboard

    func copyOne(_ entry: FileEntry, cut: Bool) {
        clipboard = FSClipboard(paths: [entry.path], isCut: cut)
        note("\(cut ? "Cut" : "Copied") \(entry.name)")
    }

    func copySelection(cut: Bool) {
        let paths = Array(selection)
        guard !paths.isEmpty else { return }
        clipboard = FSClipboard(paths: paths, isCut: cut)
        note("\(cut ? "Cut" : "Copied") \(paths.count) item(s)")
        exitSelection()
    }

    func clearClipboard() { clipboard = FSClipboard(paths: [], isCut: false) }

    func paste() {
        let itemsToPaste = clipboard.paths
        let cut = clipboard.isCut
        guard !itemsToPaste.isEmpty else { return }
        let dest = path
        Task.detached(priority: .userInitiated) { [weak self] in
            var ok = 0
            var failures: [String] = []
            for src in itemsToPaste {
                let name = (src as NSString).lastPathComponent
                let dst = LocalFS.uniquePath(parent: dest, name: name)
                do {
                    if cut {
                        try LocalFS.move(src, to: dst)
                    } else {
                        try LocalFS.copy(src, to: dst)
                    }
                    ok += 1
                } catch {
                    failures.append("\(name): \(error.localizedDescription)")
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.note("Pasted \(ok) item(s) into \(dest) ✅")
                for f in failures { self.note("Paste failed — \(f)") }
                if cut { self.clearClipboard() }
                self.reload()
            }
        }
    }

    // MARK: - CRUD

    func newFolder() {
        alertKind = .newFolder
        alertTitle = t("new.folder")
        alertMessage = t("created.in") + " " + path
        alertPlaceholder = t("folder.name")
        alertText = ""
        alertActionLabel = t("create")
        showAlert = true
    }

    func newFile() {
        alertKind = .newFile
        alertTitle = t("new.file")
        alertMessage = t("created.in") + " " + path
        alertPlaceholder = "file.txt"
        alertText = ""
        alertActionLabel = t("create")
        showAlert = true
    }

    func beginRename(_ entry: FileEntry) {
        alertKind = .rename(entry.path)
        alertTitle = t("rename")
        alertMessage = entry.name
        alertPlaceholder = entry.name
        alertText = entry.name
        alertActionLabel = t("rename")
        showAlert = true
    }

    func createSymlinkHere() {
        alertKind = .symlink
        alertTitle = t("new.symlink")
        alertMessage = t("symlink.target")
        alertPlaceholder = "/path/to/target"
        alertText = ""
        alertActionLabel = t("create")
        showAlert = true
    }

    /// The single action behind every text alert.
    func alertAction() {
        let text = alertText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch alertKind {
        case .newFolder:
            let target = LocalFS.uniquePath(parent: path, name: text)
            do {
                try LocalFS.createDirectory(at: target)
                note("Created folder \(target) ✅")
                reload()
            } catch { note("mkdir failed: \(error.localizedDescription)") }
        case .newFile:
            let target = LocalFS.uniquePath(parent: path, name: text)
            do {
                try LocalFS.createFile(at: target)
                note("Created file \(target) ✅")
                reload()
            } catch { note("touch failed: \(error.localizedDescription)") }
        case .rename(let oldPath):
            let parent = (oldPath as NSString).deletingLastPathComponent
            let target = parent + "/" + text
            do {
                try LocalFS.rename(oldPath, to: target)
                note("Renamed to \(text) ✅")
                reload()
            } catch { note("Rename failed: \(error.localizedDescription)") }
        case .goTo:
            go(to: text)
        case .symlink:
            let target = LocalFS.uniquePath(parent: path, name: "link")
            do {
                try LocalFS.createSymlink(at: target, to: text)
                note("Created symlink \(target) → \(text) ✅")
                reload()
            } catch { note("Symlink failed: \(error.localizedDescription)") }
        }
    }

    func duplicate(_ entry: FileEntry) {
        let parent = (entry.path as NSString).deletingLastPathComponent
        let dst = LocalFS.uniquePath(parent: parent, name: entry.name)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try LocalFS.copy(entry.path, to: dst)
                await MainActor.run { [weak self] in
                    self?.note("Duplicated \(entry.name) ✅")
                    self?.reload()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.note("Duplicate failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func confirmDelete(_ entry: FileEntry) {
        confirmKind = .deleteOne(entry.path)
        confirmTitle = t("delete") + " " + entry.name + "?"
        confirmMessage = entry.isDir ? t("delete.folder.warning") : t("delete.file.warning")
        showConfirm = true
    }

    func confirmDeleteSelection() {
        guard !selection.isEmpty else { return }
        confirmKind = .deleteSelection
        confirmTitle = t("delete") + " \(selection.count)?"
        confirmMessage = t("delete.file.warning")
        showConfirm = true
    }

    func confirmAction() {
        switch confirmKind {
        case .deleteOne(let p):
            deletePaths([p])
        case .deleteSelection:
            deletePaths(Array(selection))
            exitSelection()
        }
    }

    private func deletePaths(_ paths: [String]) {
        Task.detached(priority: .userInitiated) { [weak self] in
            var ok = 0
            var failures: [String] = []
            for p in paths {
                do {
                    try LocalFS.remove(p)
                    ok += 1
                } catch {
                    failures.append("\((p as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.note("Deleted \(ok) item(s) ✅")
                for f in failures { self.note("Delete failed — \(f)") }
                self.reload()
            }
        }
    }

    // MARK: - Share

    func share(_ entry: FileEntry) {
        state?.share(url: URL(fileURLWithPath: entry.path))
    }

    func shareSelection() {
        let paths = Array(selection)
        guard !paths.isEmpty else { return }
        if paths.count == 1 {
            state?.share(url: URL(fileURLWithPath: paths[0]))
        } else {
            // Zip them so one URL can carry everything.
            compress(paths: paths)
        }
    }

    // MARK: - Info / preview / edit

    func showInfoFor(_ entry: FileEntry) {
        infoPath = entry.path
        showInfo = true
    }

    func quickLook(_ entry: FileEntry) {
        quickLookPath = entry.path
        showQuickLook = true
    }

    func edit(_ entry: FileEntry) {
        editorPath = entry.path
        showEditor = true
    }

    // MARK: - Favorites

    func addFavorite(_ p: String) {
        if !favorites.contains(p) {
            favorites.append(p)
            note("⭐️ \(p)")
        }
    }

    // MARK: - Search

    func enterSearch() {
        // Filter-in-place is covered by typing into the deep search; open the
        // recursive search scoped to the current folder.
        exitSearch()
        inSearchResults = true
        searchResults = []
        isSearching = true
        let root = path
        let query = (title == "/" ? "" : title) // start broad; user refines below
        let effective = query.isEmpty ? "" : query
        activeSearchDescription = t("search.in") + " " + root
        let showHiddenNow = showHidden
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Recursive search honours the current folder name when non-root so
            // the first pass is useful; the sheet refines with typed text.
            _ = effective
            let results = LocalFS.search(root: root, query: "", limit: 400) { _ in
                Task.isCancelled
            }
            await MainActor.run { [weak self] in
                guard let self, self.inSearchResults else { return }
                self.searchResults = results.filter {
                    showHiddenNow || !((($0 as NSString).lastPathComponent).hasPrefix("."))
                }
                self.isSearching = false
                self.note("Search under \(root): \(results.count) matches")
            }
        }
    }

    /// Refines the current search by name.
    func refineSearch(_ query: String) {
        guard inSearchResults else { return }
        let q = query.lowercased()
        guard !q.isEmpty else { return }
        let root = path
        isSearching = true
        searchTask?.cancel()
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let results = LocalFS.search(root: root, query: q, limit: 400) { _ in
                Task.isCancelled
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    func exitSearch() {
        searchTask?.cancel()
        searchTask = nil
        inSearchResults = false
        searchResults = []
        isSearching = false
        activeSearchDescription = nil
    }

    // MARK: - ZIP

    func compress(_ entry: FileEntry) {
        compress(paths: [entry.path])
    }

    func compressSelection() {
        let paths = Array(selection)
        guard !paths.isEmpty else { return }
        exitSelection()
        compress(paths: paths)
    }

    private func compress(paths: [String]) {
        guard let first = paths.first else { return }
        let parent = (first as NSString).deletingLastPathComponent
        let baseName = paths.count == 1
            ? ((first as NSString).lastPathComponent as NSString).deletingPathExtension
            : "Archive"
        let zipPath = LocalFS.uniquePath(parent: parent, name: baseName + ".zip")
        note("Compressing \(paths.count) item(s)…")
        Task.detached(priority: .userInitiated) { [weak self] in
            var inputs: [ZipArchive.Input] = []
            func add(_ path: String, relName: String) {
                let a = LocalFS.attrs(at: path)
                guard let a else { return }
                if a.isLink {
                    inputs.append(ZipArchive.Input(
                        name: relName, isDir: false, data: Data(),
                        linkTarget: a.linkTarget
                    ))
                } else if a.isDir {
                    inputs.append(ZipArchive.Input(
                        name: relName + "/", isDir: true, data: Data(), linkTarget: nil
                    ))
                    let fm = FileManager.default
                    let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
                    for n in names.sorted() {
                        add(path + "/" + n, relName: relName + "/" + n)
                    }
                } else {
                    let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
                    inputs.append(ZipArchive.Input(
                        name: relName, isDir: false, data: data, linkTarget: nil
                    ))
                }
            }
            for p in paths {
                add(p, relName: (p as NSString).lastPathComponent)
            }
            do {
                let zip = try ZipArchive.build(inputs)
                try zip.write(to: URL(fileURLWithPath: zipPath), options: .atomic)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.note("Created \(zipPath) (\(FileEntry.prettySize(Int64(zip.count)))) ✅")
                    self.reload()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.note("Compress failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func extract(_ entry: FileEntry) {
        let parent = (entry.path as NSString).deletingLastPathComponent
        let folderName = ((entry.name as NSString).deletingPathExtension)
        let destDir = LocalFS.uniquePath(parent: parent, name: folderName)
        note("Extracting \(entry.name)…")
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: entry.path)) else {
                    throw NSError(domain: "Zip", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Cannot read the archive"])
                }
                let entries = try ZipArchive.entries(data: data)
                let fm = FileManager.default
                try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
                var extracted = 0
                for e in entries {
                    // Path traversal guard: no "..", no absolute escapes.
                    let rel = e.name.replacingOccurrences(of: "\\", with: "/")
                    if rel.contains("..") || rel.hasPrefix("/") {
                        continue
                    }
                    let target = destDir + "/" + rel
                    if e.isDirectory {
                        try? fm.createDirectory(atPath: target, withIntermediateDirectories: true)
                        continue
                    }
                    let payload = try ZipArchive.extractEntry(e, from: data)
                    let dir = (target as NSString).deletingLastPathComponent
                    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    if e.isSymlink, let targetPath = e.linkTarget {
                        try? fm.removeItem(atPath: target)
                        try? fm.createSymbolicLink(atPath: target, withDestinationPath: targetPath)
                    } else {
                        try payload.write(to: URL(fileURLWithPath: target), options: .atomic)
                    }
                    extracted += 1
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.note("Extracted \(extracted) file(s) into \(destDir) ✅")
                    self.reload()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.note("Extract failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Path convenience

extension FileEntry {
    /// Builds a minimal entry from just a path (search results).
    init(entryForPath path: String) {
        let a = LocalFS.attrs(at: path)
        self.init(
            path: path,
            name: (path as NSString).lastPathComponent,
            isDir: a?.isDir ?? false,
            isLink: a?.isLink ?? false,
            size: a?.size ?? 0,
            modified: a?.modified ?? .distantPast,
            permissions: a?.permissions ?? 0,
            linkTarget: a?.linkTarget
        )
    }
}
