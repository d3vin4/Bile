import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var pairingStatus: String = ""
    @Published var hasPairingFile: Bool = false
    @Published var pairingFileName: String = ""
    @Published var pairingPIN: String? = nil
    @Published var pairingPhase: PairingPhase = .idle
    @Published var deviceIP: String = "10.7.0.1"

    @Published var apps: [AppEntry] = []
    @Published var groups: [GroupEntry] = []
    @Published var isLoadingCatalog = false
    @Published var catalogError: String? = nil

    @Published var selectedContainer: (path: String, bundleId: String, name: String)? = nil
    @Published var bridge: String = ""
    @Published var bridgeMode: String = ""
    @Published var currentRelPath: String = ""
    @Published var entries: [FileEntry] = []
    @Published var isLoadingFiles = false
    @Published var filesError: String? = nil

    @Published var log: [String] = []
    @Published var exportedFileURL: URL? = nil
    @Published var showShareSheet: Bool = false

    enum PairingPhase: Equatable { case idle, pairing }

    var pairingPath: String { PairingController.pairingFilePath() }

    func logLine(_ s: String) { log.append(s) }

    func refreshPairingFile() {
        let path = PairingController.pairingFilePath()
        let exists = FileManager.default.fileExists(atPath: path) &&
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) > 0
        hasPairingFile = exists
        pairingFileName = exists ? (path as NSString).lastPathComponent : ""
    }

    func loadCatalog() {
        guard hasPairingFile else { catalogError = "No pairing file"; return }
        isLoadingCatalog = true
        catalogError = nil
        Task {
            do {
                let (a, g) = try RustBridge.catalog(pairingPath: pairingPath, log: { [weak self] in self?.logLine($0) })
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

    func openContainer(path: String, bundleId: String, name: String) {
        selectedContainer = (path, bundleId, name)
        bridge = ""
        bridgeMode = ""
        currentRelPath = ""
        entries = []
        Task {
            do {
                let (b, m) = try RustBridge.bridgeOpen(pairingPath: pairingPath, containerPath: path, log: { [weak self] in self?.logLine($0) })
                await MainActor.run {
                    self.bridge = b
                    self.bridgeMode = m
                }
                await loadFiles()
            } catch {
                await MainActor.run { self.filesError = error.localizedDescription }
            }
        }
    }

    func closeContainer() {
        if !bridge.isEmpty {
            RustBridge.bridgeClose(pairingPath: pairingPath, bridge: bridge, log: { [weak self] in self?.logLine($0) })
        }
        selectedContainer = nil
        bridge = ""
        bridgeMode = ""
        entries = []
        currentRelPath = ""
    }

    func loadFiles() {
        guard let c = selectedContainer else { return }
        isLoadingFiles = true
        filesError = nil
        Task {
            do {
                let list = try RustBridge.list(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: currentRelPath, bridge: bridge, log: { [weak self] in self?.logLine($0) })
                var out: [FileEntry] = []
                for d in list {
                    out.append(FileEntry(
                        id: (d["name"] as? String) ?? UUID().uuidString,
                        name: (d["name"] as? String) ?? "",
                        isDir: (d["isDir"] as? Bool) ?? false,
                        size: (d["size"] as? Int) ?? 0,
                        modified: (d["modified"] as? String) ?? ""
                    ))
                }
                out.sort { (a, b) in
                    if a.isDir != b.isDir { return a.isDir }
                    return a.name < b.name
                }
                await MainActor.run {
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
        if currentRelPath.isEmpty { currentRelPath = dir } else { currentRelPath += "/" + dir }
        loadFiles()
    }

    func navigateUp() {
        if currentRelPath.isEmpty { return }
        var parts = currentRelPath.split(separator: "/").map(String.init)
        parts.removeLast()
        currentRelPath = parts.joined(separator: "/")
        loadFiles()
    }

    func breadcrumb() -> String {
        if currentRelPath.isEmpty { return "/" }
        return "/" + currentRelPath
    }

    func exportFile(_ entry: FileEntry, to destURL: URL) {
        guard let c = selectedContainer else { return }
        let rel = currentRelPath.isEmpty ? entry.name : currentRelPath + "/" + entry.name
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name).path
        Task {
            do {
                try RustBridge.read(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge, destLocalPath: local, log: { [weak self] in self?.logLine($0) })
                // copy to dest
                let src = URL(fileURLWithPath: local)
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.copyItem(at: src, to: destURL)
                await MainActor.run { logLine("Exported \(entry.name) ✅") }
            } catch {
                await MainActor.run { logLine("Export failed: \(error.localizedDescription)") }
            }
        }
    }

    func deleteEntry(_ entry: FileEntry) {
        guard let c = selectedContainer else { return }
        let rel = currentRelPath.isEmpty ? entry.name : currentRelPath + "/" + entry.name
        Task {
            do {
                try RustBridge.remove(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge, log: { [weak self] in self?.logLine($0) })
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
                try RustBridge.mkdir(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge, log: { [weak self] in self?.logLine($0) })
                await MainActor.run { loadFiles() }
            } catch {
                await MainActor.run { logLine("Mkdir failed: \(error.localizedDescription)") }
            }
        }
    }

    func renameEntry(_ entry: FileEntry, to newName: String) {
        guard let c = selectedContainer else { return }
        let oldRel = currentRelPath.isEmpty ? entry.name : currentRelPath + "/" + entry.name
        let newRel = currentRelPath.isEmpty ? newName : currentRelPath + "/" + newName
        Task {
            do {
                try RustBridge.rename(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, oldRel: oldRel, newRel: newRel, bridge: bridge, log: { [weak self] in self?.logLine($0) })
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
                try RustBridge.write(pairingPath: pairingPath, bundleId: c.bundleId, containerPath: c.path, relPath: rel, bridge: bridge, srcLocalPath: local, log: { [weak self] in self?.logLine($0) })
                await MainActor.run { loadFiles() }
            } catch {
                await MainActor.run { logLine("Import failed: \(error.localizedDescription)") }
            }
        }
    }
}

enum PairingPhase { case idle, pairing }
