import Foundation

struct AppEntry: Identifiable, Hashable {
    let id: String // bundleId
    let bundleId: String
    let name: String
    let type: String
    let version: String
    let dataContainer: String
    let groupContainers: [String: String]
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
    let size: Int
    let modified: String
}
