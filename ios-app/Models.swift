import Foundation

// MARK: - Tabs

enum AppTab: Int, Hashable {
    case files, apps, logs
}

// MARK: - File system entries

/// One entry in a directory listing, taken from `lstat` (so symlinks report
/// themselves, never their target).
struct FileEntry: Identifiable, Hashable {
    let path: String        // absolute path
    let name: String
    let isDir: Bool
    let isLink: Bool
    let size: Int64
    let modified: Date
    let permissions: Int    // POSIX octal, e.g. 0o644
    let linkTarget: String? // resolved target for symlinks

    var id: String { path }

    var icon: String {
        if isLink { return "link" }
        if isDir { return "folder.fill" }
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff":
            return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv":
            return "film"
        case "mp3", "m4a", "wav", "aac", "flac", "ogg":
            return "waveform"
        case "plist", "json", "xml", "yaml", "yml", "ini", "cfg", "conf":
            return "curlybraces.square"
        case "sqlite", "sqlite3", "db", "sqlite-wal", "sqlite-shm":
            return "cylinder"
        case "h", "m", "swift", "c", "cpp", "rs", "py", "js", "ts", "sh", "lua":
            return "chevron.left.forwardslash.chevron.right"
        case "txt", "md", "log", "rtf":
            return "doc.text"
        case "pdf":
            return "doc.richtext"
        case "zip", "gz", "tar", "bz2", "xz", "ipa", "deb", "aar":
            return "doc.zipper"
        case "dylib", "framework", "bundle", "app", "appex":
            return "shippingbox"
        case "ttf", "otf":
            return "textformat"
        default:
            return "doc"
        }
    }

    var ext: String {
        (name as NSString).pathExtension.lowercased()
    }

    var isTextFile: Bool {
        if isDir || isLink { return false }
        switch ext {
        case "txt", "md", "log", "json", "plist", "xml", "yaml", "yml", "html",
             "css", "js", "ts", "swift", "h", "m", "c", "cpp", "rs", "py", "sh",
             "lua", "ini", "cfg", "conf", "csv", "sql", "strings", "entitlements",
             "resigned", "mobileprovision":
            return true
        default:
            return false
        }
    }

    static func prettySize(_ bytes: Int64) -> String {
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

    var permissionsString: String {
        String(format: "%o", permissions)
    }
}

// MARK: - Sort & view options

enum SortOrder: String, CaseIterable, Identifiable {
    case nameAscending = "sort.name.asc"
    case nameDescending = "sort.name.desc"
    case sizeDescending = "sort.size.desc"
    case sizeAscending = "sort.size.asc"
    case dateNewest = "sort.date.new"
    case dateOldest = "sort.date.old"

    var id: String { rawValue }

    var labelKey: String { rawValue }
}

enum ViewMode: String, CaseIterable {
    case list, grid
}

// MARK: - Clipboard (in-app)

struct FSClipboard: Equatable {
    var paths: [String]
    var isCut: Bool
    var isEmpty: Bool { paths.isEmpty }
}

// MARK: - Installed apps

/// One installed application as reported by LaunchServices.
struct AppEntry: Identifiable, Hashable {
    let bundleId: String
    let name: String
    let version: String
    let type: String          // "user" / "system"
    let bundlePath: String
    let dataContainer: String // may be empty
    let icon: Data?           // PNG bytes if the bundle exposed one

    var id: String { bundleId }

    var isReadable: Bool {
        !dataContainer.isEmpty && FileManager.default.isReadableFile(atPath: dataContainer)
    }
}
