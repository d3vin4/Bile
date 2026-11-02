import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Pairing / tunnel

    @Published var pairingStatus: String = ""
    @Published var hasPairingFile: Bool = false
    @Published var pairingFileName: String = ""
    @Published var pairingPIN: String? = nil
    @Published var deviceIP: String = "10.7.0.1"
    @Published var tunnelResults: [TunnelProbe.Result] = []
    @Published var isTestingTunnel = false
    @Published var liveActivitiesEnabled = false

    // MARK: - Catalog

    @Published var apps: [AppEntry] = []
    @Published var groups: [GroupEntry] = []
    @Published var isLoadingCatalog = false
    @Published var catalogError: String? = nil

    // MARK: - Browsing

    @Published var selectedContainer: (path: String, bundleId: String, name: String)? = nil
    @Published var bridge: String = ""
    @Published var bridgeMode: String = ""
    @Published var currentRelPath: String = ""
    @Published var entries: [FileEntry] = []
    @Published var isLoadingFiles = false
    @Published var filesError: String? = nil
    @Published var sortOrder: SortOrder = .kind
    @Published var searchText = ""

    // MARK: - Output

    @Published var log: [String] = []
    @Published var exportedFileURL: URL? = nil
    @Published var showShareSheet: Bool = false
    @Published var previewName: String? = nil
    @Published var previewText: String? = nil
    @Published var showPreview = false
    @Published var isExporting = false
    @Published var bridgeRequiresRiskyMoves = false
    @Published var leftovers: [LeftoverEntry] = []
    @Published var selectedTab: AppTab = .setup
    @Published var pathHistory: [String] = []

    @Published var allowRiskyMoves: Bool = UserDefaults.standard.bool(forKey: "readipa.allowRiskyMoves") {
        didSet {
            UserDefaults.standard.set(allowRiskyMoves, forKey: "readipa.allowRiskyMoves")
            RustBridge.setAllowRiskyMoves(allowRiskyMoves)
        }
    }

    init() {
        // didSet does not fire during initialization.
        RustBridge.setAllowRiskyMoves(allowRiskyMoves)
        liveActivitiesEnabled = PairingController.liveActivitiesEnabled
    }

    var pairingPath: String { PairingController.pairingFilePath() }

    // MARK: - Helpers

    func logLine(_ s: String) { log.append(s) }

    var sortedEntries: [FileEntry] {
        let query = searchText.lowercased()
        let filtered = query.isEmpty
            ? entries
            : entries.filter { $0.name.lowercased().contains(query) }

        switch sortOrder {
        case .nameAscending:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .sizeDescending:
            return filtered.sorted { $0.size > $1.size }
        case .sizeAscending:
            return filtered.sorted { $0.size < $1.size }
        case .kind:
            return filtered.sorted { a, b in
                if a.isDir != b.isDir { return a.isDir }
                if a.isLink != b.isLink { return b.isLink }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    var currentPathDisplay: String {
        let base = selectedContainer?.name ?? ""
        return base + (currentRelPath.isEmpty ? "" : "/" + currentRelPath)
    }

    // MARK: - Pairing

    func refreshPairingFile() {
        // Touch the store so a Keychain-only pairing is restored to disk.
        let path = PairingController.pairingFilePath()
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        hasPairingFile = (data?.isEmpty == false)
        pairingFileName = hasPairingFile ? PairingStore.fileName : ""
    }

    // MARK: - Tunnel

    func testTunnel() {
        isTestingTunnel = true
        let hosts = TunnelProbe.candidates(userHost: deviceIP)
        Task.detached(priority: .userInitiated) {
            let results = TunnelProbe.probe(hosts: hosts)
            await MainActor.run {
                self.tunnelResults = results
                self.isTestingTunnel = false
                if let best = results.first(where: { $0.ok }) {
                    self.deviceIP = best.host
                    self.logLine("tunnel: using \(best.host) — \(best.summary)")
                } else {
                    self.logLine("tunnel: no reachable host. Start the loopback VPN (LocalDevVPN / StosVPN) and try again.")
                }
            }
        }
    }

    // MARK: - Catalog

    func loadCatalog() {
        guard hasPairingFile else { catalogError = "No pairing file"; return }
        isLoadingCatalog = true
        catalogError = nil
        Task {
            do {
                let (a, g) = try RustBridge.catalog(pairingPath: pairingPath)
                var apps: [AppEntry] = []
                for d in a {
                    apps.append(AppEntry(
                        id: (d["bundleId"] as? String) ?? "",
                        bundleId: (d["bundleId"] as? String) ?? "",
                        name: (d["name"] as? String) ?? "",
                        type: (d["type"] as? String) ?? "",
                        version: (d["version"] as? String) ?? "",
                        dataContainer: (d["dataContainer"] as? String) ?? "",
                        groupContainers: (d["groupContainers"] as? [String: String]) ?? [:]
                    ))
                }
                var groups: [GroupEntry] = []
                for d in g {
                    groups.append(GroupEntry(
                        id: (d["id"] as? String) ?? "",
                        path: (d["path"] as? String) ?? "",
                        owners: (d["owners"] as? [String]) ?? []
                    ))
                }
                await MainActor.run {
                    self.apps = apps.sorted { $0.name < $1.name }
                    self.groups = groups.sorted { $0.id < $1.id }
                    self.isLoadingCatalog = false
                }
            } catch {
                await MainActor.run {
                    self.catalogError = error.localizedDescription
                    self.isLoadingCatalog = false
                }
            }
        }
    }

    // MARK: - Container

    func openContainer(path: String, bundleId: String, name: String) {
        selectedTab = .files
        pathHistory = []
        selectedContainer = (path, bundleId, name)
        bridge = ""
        bridgeMode = ""
        currentRelPath = ""
        entries = []
        searchText = ""
        Task {
            do {
                let (b, m, risky) = try RustBridge.bridgeOpen(pairingPath: pairingPath, containerPath: path)
                await MainActor.run {
                    self.bridge = b
                    self.bridgeMode = m
                    self.bridgeRequiresRiskyMoves = risky
                }
                await loadFiles()
            } catch {
                await MainActor.run { self.filesError = error.localizedDescription }
            }
        }
    }

    func closeContainer() {
        if !bridge.isEmpty {
            RustBridge.bridgeClose(pairingPath: pairingPath, bridge: bridge)
        }
        selectedContainer = nil
        bridge = ""
        bridgeMode = ""
        entries = []
        currentRelPath = ""
        searchText = ""
    }

    func loadFiles() {
        guard let c = selectedContainer else { return }
        isLoadingFiles = true
        filesError = nil
        let rel = currentRelPath
        Task {
            do {
                let result = try RustBridge.list(
                    pairingPath: pairingPath,
                    bundleId: c.bundleId,
                    containerPath: c.path,
                    relPath: rel,
                    bridge: bridge
                )
                var out: [FileEntry] = []
                for d in result.entries {
                    let name = (d["name"] as? String) ?? ""
                    out.append(FileEntry(
                        id: name,
                        name: name,
                        isDir: (d["isDir"] as? Bool) ?? false,
                        isLink: (d["isLink"] as? Bool) ?? false,
                        size: (d["size"] as? Int) ?? 0,
                        modified: (d["modified"] as? String) ?? ""
                    ))
                }
                await MainActor.run {
                    if !result.bridge.isEmpty && result.bridge != self.bridge {
                        // The core recreated the bridge; adopt it.
                        self.bridge = result.bridge
                    }
                    self.entries = out
                    self.isLoadingFiles = false
                }
            } catch {
                await MainActor.run {
                    self.filesError = error.localizedDescription
                    self.isLoadingFiles = false
                }
            }
        }
    }

    func navigate(into dir: String) {
        pathHistory.append(currentRelPath)
        if currentRelPath.isEmpty { currentRelPath = dir } else { currentRelPath += "/" + dir }
        loadFiles()
    }

    var canGoBack: Bool { !pathHistory.isEmpty || !currentRelPath.isEmpty }

    /// Goes back to the previously visited folder (the "undo" for navigation).
    func navigateBack() {
        if !pathHistory.isEmpty {
            currentRelPath = pathHistory.removeLast()
        } else if !currentRelPath.isEmpty {
            var parts = currentRelPath.split(separator: "/").map(String.init)
            parts.removeLast()
            currentRelPath = parts.joined(separator: "/")
        } else {
            return
        }
        loadFiles()
    }

    func navigateHome() {
        guard !currentRelPath.isEmpty else { return }
        pathHistory.append(currentRelPath)
        currentRelPath = ""
        loadFiles()
    }

    func jump(to path: String) {
        guard path != currentRelPath else { return }
        pathHistory.append(currentRelPath)
        currentRelPath = path
        loadFiles()
    }

    func breadcrumb() -> String {
        if currentRelPath.isEmpty { return "/" }
        return "/" + currentRelPath
    }

    private func relPath(for entry: FileEntry) -> String {
        currentRelPath.isEmpty ? entry.name : currentRelPath + "/" + entry.name
    }

    // MARK: - File operations

    func exportFile(_ entry: FileEntry, to destURL: URL) {
        guard let c = selectedContainer else { return }
        let rel = relPath(for: entry)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name).path
        Task {
            do {
                try RustBridge.read(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge, destLocalPath: local)
                let src = URL(fileURLWithPath: local)
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.copyItem(at: src, to: destURL)
                await MainActor.run { logLine("Exported \(entry.name) ✅") }
            } catch {
                await MainActor.run { logLine("Export failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Reads a file into a temp copy and hands the URL to the share sheet
    /// ("Save to Files"). Never touches the original in the container.
    func shareFile(_ entry: FileEntry) {
        guard let c = selectedContainer else { return }
        let rel = relPath(for: entry)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
        logLine("Reading \(rel)…")
        Task {
            do {
                try RustBridge.read(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge, destLocalPath: local.path)
                await MainActor.run {
                    exportedFileURL = local
                    showShareSheet = true
                    logLine("Ready to save \(entry.name) ✅")
                }
            } catch {
                await MainActor.run { logLine("Export failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Safe bulk export: the Rust core walks the container read-only and writes
    /// a ZIP locally; symlinks are recorded, never followed.
    func exportContainerAsZip() {
        guard let c = selectedContainer else { return }
        isExporting = true
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let safeName = c.name.replacingOccurrences(of: "/", with: "-")
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)-\(stamp).zip")
        let rel = currentRelPath
        logLine("Exporting \(c.name)\(rel.isEmpty ? "" : "/" + rel) to ZIP…")
        Task {
            do {
                let json = try RustBridge.exportContainer(
                    pairingPath: pairingPath,
                    bundleId: c.bundleId,
                    containerPath: c.path,
                    relPath: rel,
                    bridge: bridge,
                    destZipPath: zip.path,
                    rootName: safeName
                )
                await MainActor.run {
                    isExporting = false
                    exportedFileURL = zip
                    showShareSheet = true
                    let files = (json["files"] as? Int) ?? 0
                    let bytes = (json["bytes"] as? Int) ?? 0
                    let failures = (json["failures"] as? [String]) ?? []
                    logLine("Export done: \(files) files, \(FileEntry.prettySize(bytes)) ✅")
                    if !failures.isEmpty {
                        logLine("Export warnings (\(failures.count)):")
                        for f in failures.prefix(20) { logLine("  • \(f)") }
                    }
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    logLine("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func preview(_ entry: FileEntry) {
        guard let c = selectedContainer else { return }
        let rel = relPath(for: entry)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name).path
        logLine("Loading preview of \(rel)…")
        Task {
            do {
                try RustBridge.read(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge, destLocalPath: local)
                let data = (try? Data(contentsOf: URL(fileURLWithPath: local))) ?? Data()
                let text = String(data: data.prefix(256 * 1024), encoding: .utf8)
                    ?? "(binary file — \(FileEntry.prettySize(data.count)))"
                await MainActor.run {
                    previewName = entry.name
                    previewText = text
                    showPreview = true
                }
            } catch {
                await MainActor.run { logLine("Preview failed: \(error.localizedDescription)") }
            }
        }
    }

    func deleteEntry(_ entry: FileEntry) {
        guard let c = selectedContainer else { return }
        let rel = relPath(for: entry)
        Task {
            do {
                try RustBridge.remove(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge)
                await MainActor.run { loadFiles() }
            } catch {
                await MainActor.run { logLine("Delete failed: \(error.localizedDescription)") }
            }
        }
    }

    func createFolder(name: String) {
        guard let c = selectedContainer else { return }
        let rel = currentRelPath.isEmpty ? name : currentRelPath + "/" + name
        Task {
            do {
                try RustBridge.mkdir(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge)
                await MainActor.run { loadFiles() }
            } catch {
                await MainActor.run { logLine("Mkdir failed: \(error.localizedDescription)") }
            }
        }
    }

    func renameEntry(_ entry: FileEntry, to newName: String) {
        guard let c = selectedContainer else { return }
        let oldRel = relPath(for: entry)
        let newRel = currentRelPath.isEmpty ? newName : currentRelPath + "/" + newName
        Task {
            do {
                try RustBridge.rename(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, oldRel: oldRel, newRel: newRel, bridge: bridge)
                await MainActor.run { loadFiles() }
            } catch {
                await MainActor.run { logLine("Rename failed: \(error.localizedDescription)") }
            }
        }
    }

    func importFile(from url: URL) {
        guard let c = selectedContainer else { return }
        let name = url.lastPathComponent
        let rel = currentRelPath.isEmpty ? name : currentRelPath + "/" + name
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        Task {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try data.write(to: URL(fileURLWithPath: local))
                try RustBridge.write(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge, srcLocalPath: local)
                await MainActor.run { loadFiles() }
            } catch {
                await MainActor.run { logLine("Import failed: \(error.localizedDescription)") }
            }
        }
    }

    // MARK: - Recovery

    func scanLeftovers() {
        guard hasPairingFile else { return }
        Task {
            do {
                let list = try RustBridge.mediaLeftovers(pairingPath: pairingPath)
                let entries = list.map { d -> LeftoverEntry in
                    let name = (d["name"] as? String) ?? ""
                    return LeftoverEntry(
                        id: name,
                        name: name,
                        isDir: (d["isDir"] as? Bool) ?? false,
                        isLink: (d["isLink"] as? Bool) ?? false,
                        size: (d["size"] as? Int) ?? 0,
                        modified: (d["modified"] as? String) ?? "",
                        kind: (d["kind"] as? String) ?? "temporary item",
                        safeToRemove: (d["safeToRemove"] as? Bool) ?? false
                    )
                }
                await MainActor.run { self.leftovers = entries }
            } catch {
                await MainActor.run { logLine("Recovery scan failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Removes only leftovers that provably hold no data.
    func cleanupLeftovers() {
        guard hasPairingFile else { return }
        Task {
            do {
                let json = try RustBridge.cleanupLeftovers(pairingPath: pairingPath)
                let removed = (json["removed"] as? Int) ?? 0
                let kept = (json["kept"] as? Int) ?? 0
                await MainActor.run {
                    logLine("Cleanup: removed \(removed) empty leftovers, kept \(kept) that contain data")
                    scanLeftovers()
                }
            } catch {
                await MainActor.run { logLine("Cleanup failed: \(error.localizedDescription)") }
            }
        }
    }

    func deleteLeftover(_ item: LeftoverEntry) {
        Task {
            do {
                try RustBridge.deleteLeftover(pairingPath: pairingPath, name: item.name)
                await MainActor.run {
                    logLine("Deleted leftover \(item.name)")
                    scanLeftovers()
                }
            } catch {
                await MainActor.run { logLine("Delete failed: \(error.localizedDescription)") }
            }
        }
    }

    /// Writes the log to a text file and hands it to the share sheet.
    func shareLogs() {
        let header = """
        Readipa log
        date: \(Date())
        pairing: \(hasPairingFile ? "present" : "missing")
        engine: \(bridgeMode.isEmpty ? "-" : bridgeMode)
        tunnel host: \(deviceIP)
        risky moves: \(allowRiskyMoves)

        """
        let text = header + log.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("readipa-log-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportedFileURL = url
            showShareSheet = true
        } catch {
            logLine("Could not write the log file: \(error.localizedDescription)")
        }
    }

    /// Restore a leftover into `<folder>/<original name>` of the open container.
    func recoverLeftover(_ item: LeftoverEntry, intoFolder folder: String) {
        guard let c = selectedContainer else {
            logLine("Open the destination container first, then pick where to restore it")
            return
        }
        let cleaned = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let rel = cleaned.isEmpty ? item.name : cleaned + "/" + item.name
        Task {
            do {
                try RustBridge.recoverLeftover(
                    pairingPath: pairingPath,
                    leftoverName: item.name,
                    containerPath: c.path,
                    relPath: rel,
                    bridge: bridge
                )
                await MainActor.run {
                    logLine("Recovered \(item.name) → \(rel) ✅")
                    scanLeftovers()
                    loadFiles()
                }
            } catch {
                await MainActor.run { logLine("Recovery failed: \(error.localizedDescription)") }
            }
        }
    }
}
