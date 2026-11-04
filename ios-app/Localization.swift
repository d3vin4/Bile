import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case vietnamese = "vi"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .english: return "English"
        case .vietnamese: return "Tiếng Việt"
        }
    }
}

/// Tiny in-app localiser. Views call `lang("some.key")`; because `t(_:)` reads
/// the published `language`, SwiftUI re-renders the whole hierarchy when the
/// user switches language.
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "readipa.language") }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: "readipa.language") ?? "en"
        language = AppLanguage(rawValue: raw) ?? .english
    }

    func t(_ key: String) -> String {
        Self.strings[key]?[language] ?? Self.strings[key]?[.english] ?? key
    }

    /// Shorthand: `lang("tab.files")`.
    func callAsFunction(_ key: String) -> String { t(key) }

    static let strings: [String: [AppLanguage: String]] = [
        // Tabs
        "tab.files": [.english: "Files", .vietnamese: "Tệp"],
        "tab.apps": [.english: "Apps", .vietnamese: "Ứng dụng"],
        "tab.logs": [.english: "Logs", .vietnamese: "Nhật ký"],

        // Generic actions
        "open": [.english: "Open", .vietnamese: "Mở"],
        "cancel": [.english: "Cancel", .vietnamese: "Huỷ"],
        "done": [.english: "Done", .vietnamese: "Xong"],
        "create": [.english: "Create", .vietnamese: "Tạo"],
        "apply": [.english: "Apply", .vietnamese: "Áp dụng"],
        "save": [.english: "Save", .vietnamese: "Lưu"],
        "clear": [.english: "Clear", .vietnamese: "Xoá"],
        "delete": [.english: "Delete", .vietnamese: "Xoá"],
        "delete.permanently": [.english: "Delete permanently", .vietnamese: "Xoá vĩnh viễn"],
        "rename": [.english: "Rename", .vietnamese: "Đổi tên"],
        "duplicate": [.english: "Duplicate", .vietnamese: "Nhân bản"],
        "copy": [.english: "Copy", .vietnamese: "Sao chép"],
        "cut": [.english: "Cut", .vietnamese: "Cắt"],
        "paste": [.english: "Paste", .vietnamese: "Dán"],
        "share": [.english: "Share", .vietnamese: "Chia sẻ"],
        "select": [.english: "Select", .vietnamese: "Chọn"],
        "info": [.english: "Info", .vietnamese: "Thông tin"],
        "preview": [.english: "Preview", .vietnamese: "Xem trước"],
        "edit": [.english: "Edit", .vietnamese: "Sửa"],
        "compress": [.english: "Compress to ZIP", .vietnamese: "Nén thành ZIP"],
        "extract": [.english: "Extract", .vietnamese: "Giải nén"],
        "size": [.english: "Size", .vietnamese: "Dung lượng"],
        "permissions": [.english: "Permissions", .vietnamese: "Quyền"],
        "go": [.english: "Go", .vietnamese: "Đi"],
        "go.to.path": [.english: "Go to path", .vietnamese: "Đến đường dẫn"],
        "recent": [.english: "Recent", .vietnamese: "Gần đây"],
        "favorites": [.english: "Favorites", .vietnamese: "Yêu thích"],
        "favorite.add": [.english: "Add to Favorites", .vietnamese: "Thêm vào Yêu thích"],
        "no.favorites": [.english: "No favorites yet", .vietnamese: "Chưa có mục yêu thích"],
        "search.close": [.english: "Close", .vietnamese: "Đóng"],
        "search.in": [.english: "Searching in", .vietnamese: "Đang tìm trong"],
        "calculating": [.english: "Calculating…", .vietnamese: "Đang tính…"],
        "calculate.size": [.english: "Calculate folder size", .vietnamese: "Tính dung lượng thư mục"],

        // File browser
        "empty.folder": [.english: "Empty folder", .vietnamese: "Thư mục rỗng"],
        "new.folder": [.english: "New Folder", .vietnamese: "Thư mục mới"],
        "new.file": [.english: "New File", .vietnamese: "Tệp mới"],
        "new.symlink": [.english: "New Symlink", .vietnamese: "Liên kết mới"],
        "symlink.target": [.english: "Symlink target path", .vietnamese: "Đường dẫn đích của liên kết"],
        "folder.name": [.english: "Name", .vietnamese: "Tên"],
        "created.in": [.english: "Created in", .vietnamese: "Tạo trong"],
        "show.hidden": [.english: "Show hidden files", .vietnamese: "Hiện tệp ẩn"],
        "sort": [.english: "Sort by", .vietnamese: "Sắp xếp"],
        "sort.name.asc": [.english: "Name ↑", .vietnamese: "Tên ↑"],
        "sort.name.desc": [.english: "Name ↓", .vietnamese: "Tên ↓"],
        "sort.size.desc": [.english: "Largest first", .vietnamese: "Lớn trước"],
        "sort.size.asc": [.english: "Smallest first", .vietnamese: "Nhỏ trước"],
        "sort.date.new": [.english: "Newest first", .vietnamese: "Mới nhất"],
        "sort.date.old": [.english: "Oldest first", .vietnamese: "Cũ nhất"],
        "list.view": [.english: "List view", .vietnamese: "Dạng danh sách"],
        "grid.view": [.english: "Grid view", .vietnamese: "Dạng lưới"],
        "delete.file.warning": [.english: "This will be deleted immediately. There is no trash bin.",
                                .vietnamese: "Sẽ bị xoá ngay lập tức. Không có thùng rác."],
        "delete.folder.warning": [.english: "The folder and everything inside will be deleted immediately. There is no trash bin.",
                                   .vietnamese: "Thư mục và mọi thứ bên trong sẽ bị xoá ngay. Không có thùng rác."],
        "filter.logs": [.english: "Filter logs", .vietnamese: "Lọc nhật ký"],

        // Apps tab
        "apps": [.english: "Apps", .vietnamese: "Ứng dụng"],
        "search.apps": [.english: "Search apps or bundle id", .vietnamese: "Tìm app hoặc bundle id"],
        "apps.unavailable": [.english: "iOS did not let Readipa enumerate installed apps. Pull to retry — this needs no escape, LaunchServices sometimes refuses right after install.",
                              .vietnamese: "iOS không cho Readipa liệt kê app. Kéo để thử lại — việc này không cần escape, LaunchServices đôi khi từ chối ngay sau khi cài."],
        "container.locked": [.english: "iOS denies access to this container right now. It will open once a sandbox escape ships.",
                              .vietnamese: "iOS đang chặn truy cập container này. Sẽ mở được khi có sandbox escape."],
        "app.groups": [.english: "App Groups", .vietnamese: "App Group"],

        // Misc
        "type": [.english: "Type", .vietnamese: "Loại"],
        "folder": [.english: "Folder", .vietnamese: "Thư mục"],
        "version": [.english: "Version", .vietnamese: "Phiên bản"],
        "copy.path": [.english: "Copy path", .vietnamese: "Sao chép đường dẫn"],
        "data.container": [.english: "Data Container", .vietnamese: "Data Container"],
        "no.container": [.english: "This app has no data container", .vietnamese: "App này không có data container"],
        "loading": [.english: "Loading…", .vietnamese: "Đang tải…"],
        "language": [.english: "Language", .vietnamese: "Ngôn ngữ"],
    ]
}
