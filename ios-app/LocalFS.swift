import Foundation
import Compression

/// All file-system operations behind one small facade.
/// Everything is pure `FileManager` + `lstat` — no private API, no escapes.
enum LocalFS {

    // MARK: - Attributes

    struct Attrs {
        var isDir: Bool
        var isLink: Bool
        var size: Int64
        var modified: Date
        var created: Date?
        var permissions: Int
        var linkTarget: String?
        var owner: String?
        var group: String?

        var permissionsString: String {
            String(format: "%o", permissions)
        }
    }

    static func attrs(at path: String) -> Attrs? {
        let fm = FileManager.default
        guard let raw = try? fm.attributesOfItem(atPath: path) else { return nil }
        let type = raw[.type] as? FileAttributeType
        var isLink = false
        if type == .typeSymbolicLink { isLink = true }
        var linkTarget: String? = nil
        if isLink {
            linkTarget = try? fm.destinationOfSymbolicLink(atPath: path)
        }
        // A symlink pointing at a directory should still open like one.
        let isDir = (type == .typeDirectory)
            || (isLink && {
                guard let target = linkTarget else { return false }
                let resolved = target.hasPrefix("/") ? target : resolveDir(path, relative: target)
                var st = stat()
                return lstat(resolved, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
            }())
        return Attrs(
            isDir: isDir,
            isLink: isLink,
            size: (raw[.size] as? NSNumber)?.int64Value ?? 0,
            modified: (raw[.modificationDate] as? Date) ?? Date.distantPast,
            created: raw[.creationDate] as? Date,
            permissions: (raw[.posixPermissions] as? NSNumber)?.intValue ?? 0,
            linkTarget: linkTarget,
            owner: raw[.ownerAccountName] as? String,
            group: raw[.groupOwnerAccountName] as? String
        )
    }

    /// Resolves `relative` (as stored inside a symlink) against the directory
    /// that contains the link.
    private static func resolveDir(_ linkPath: String, relative: String) -> String {
        let dir = (linkPath as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: dir).appendingPathComponent(relative).path
    }

    // MARK: - Listing

    static func list(_ path: String, showHidden: Bool) throws -> [FileEntry] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: path)
        var out: [FileEntry] = []
        out.reserveCapacity(names.count)
        for name in names {
            if !showHidden && name.hasPrefix(".") { continue }
            let full = path.hasSuffix("/") ? path + name : path + "/" + name
            let a = attrs(at: full) ?? Attrs(
                isDir: false, isLink: false, size: 0,
                modified: .distantPast, created: nil,
                permissions: 0, linkTarget: nil, owner: nil, group: nil
            )
            out.append(FileEntry(
                path: full,
                name: name,
                isDir: a.isDir,
                isLink: a.isLink,
                size: a.size,
                modified: a.modified,
                permissions: a.permissions,
                linkTarget: a.linkTarget
            ))
        }
        return out
    }

    // MARK: - CRUD

    @discardableResult
    static func createDirectory(at path: String) throws -> String {
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: false
        )
        return path
    }

    @discardableResult
    static func createFile(at path: String, contents: Data = Data()) throws -> String {
        try contents.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    static func readData(_ path: String, limit: Int = 8 * 1024 * 1024) throws -> Data {
        let size = attrs(at: path)?.size ?? 0
        guard size <= limit else {
            throw NSError(
                domain: "LocalFS", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "File too large to read (\(FileEntry.prettySize(size)))"]
            )
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func writeData(_ path: String, _ data: Data) throws {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Recursive delete that never descends into a symlink — a link is removed
    /// as a single entry and its target is never touched. `removeItem` follows
    /// that same rule for links, so a plain call is safe here.
    static func remove(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    static func rename(_ oldPath: String, to newPath: String) throws {
        try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
    }

    /// Recursive copy; symlinks are copied as links, not followed.
    static func copy(_ from: String, to dst: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst) {
            throw NSError(
                domain: "LocalFS", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Destination already exists"]
            )
        }
        try fm.copyItem(atPath: from, toPath: dst)
    }

    static func move(_ from: String, to dst: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst) {
            throw NSError(
                domain: "LocalFS", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Destination already exists"]
            )
        }
        try fm.moveItem(atPath: from, toPath: dst)
    }

    @discardableResult
    static func createSymlink(at path: String, to target: String) throws -> String {
        try FileManager.default.createSymbolicLink(
            atPath: path, withDestinationPath: target
        )
        return path
    }

    static func setPermissions(_ path: String, mode: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path
        )
    }

    // MARK: - Sizes

    /// Recursive byte count; symlinks are never followed.
    static func size(of path: String) -> Int64 {
        let fm = FileManager.default
        guard let a = attrs(at: path) else { return 0 }
        if a.isLink { return a.size }
        guard a.isDir else { return a.size }
        var total: Int64 = 0
        let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        for name in names {
            total += size(of: path + "/" + name)
        }
        return total
    }

    /// Number of items inside a directory (non-recursive).
    static func count(in path: String) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: path))?.count ?? 0
    }

    // MARK: - Search

    /// Breadth-first name search under `root` (symlinks skipped), up to `limit`.
    static func search(root: String, query: String, limit: Int = 300,
                       progress: ((String) -> Bool)? = nil) -> [String] {
        let fm = FileManager.default
        let q = query.lowercased()
        var results: [String] = []
        var queue: [String] = [root]
        var visited = 0
        while !queue.isEmpty && results.count < limit {
            let dir = queue.removeFirst()
            visited += 1
            if visited % 50 == 0, let stop = progress?(dir), stop {
                break
            }
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for name in names {
                let full = dir + "/" + name
                if name.lowercased().contains(q) {
                    results.append(full)
                    if results.count >= limit { break }
                }
                if let a = attrs(at: full), a.isDir, !a.isLink {
                    queue.append(full)
                }
            }
        }
        return results
    }

    // MARK: - Uniqueness

    /// Returns `parent/name` or `parent/name 2`, `name 3`… whichever is free.
    static func uniquePath(parent: String, name: String) -> String {
        let fm = FileManager.default
        var candidate = parent + "/" + name
        if !fm.fileExists(atPath: candidate) { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let try_ = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = parent + "/" + try_
            n += 1
        } while fm.fileExists(atPath: candidate)
        return candidate
    }

    // MARK: - Text detection

    /// Cheap heuristic: UTF-8 decodable and no NUL bytes in the first 4 KB.
    static func looksLikeText(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 4096)
        if head.isEmpty { return true }
        if head.contains(0) { return false }
        return String(data: head, encoding: .utf8) != nil
    }
}
