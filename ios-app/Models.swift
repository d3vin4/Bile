import Foundation

struct AppEntry: Identifiable, Hashable {
    let id: String // bundleId
    let bundleId: String
    let name: String
    let type: String
    let version: String
    let dataContainer: String
    let groupContainers: [String: String]
    let getTaskAllow: Bool
    let fileSharing: Bool

    /// What iOS will actually let Readipa do with this app's container.
    var access: String {
        if getTaskAllow { return "full" }
        if fileSharing { return "documents" }
        return "none"
    }
}

struct GroupEntry: Identifiable, Hashable {
    let id: String
    let path: String
    let owners: [String]
}

struct FileEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let isDir: Bool
    let isLink: Bool
    let size: Int
    let modified: String

    var iconName: String {
        if isLink { return "link" }
        if isDir { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "m4v": return "film"
        case "mp3", "m4a", "wav", "aac": return "waveform"
        case "plist", "json", "xml": return "curlybraces"
        case "sqlite", "db", "sqlite3", "sqlite-wal", "sqlite-shm": return "cylinder"
        case "txt", "md", "log": return "doc.text"
        case "zip", "ipa", "dylib", "framework": return "shippingbox"
        default: return "doc"
        }
    }

    static func prettySize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[index])
    }
}

/// A temporary item this app (or its ancestor code) left in /var/mobile/Media.
struct LeftoverEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let isDir: Bool
    let isLink: Bool
    let size: Int
    let modified: String
    let kind: String
    let safeToRemove: Bool

    var explain: String {
        if isLink { return "bridge link — holds no data" }
        if safeToRemove { return "\(kind) — empty" }
        return "\(kind) — contains data"
    }
}

enum AppTab: Int, Hashable {
    case setup, apps, files, logs
}

enum SortOrder: String, CaseIterable, Identifiable {
    case nameAscending = "Name ↑"
    case nameDescending = "Name ↓"
    case sizeDescending = "Largest first"
    case sizeAscending = "Smallest first"
    case kind = "Kind"

    var id: String { rawValue }
}
