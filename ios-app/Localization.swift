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

    /// Shorthand: `lang("setup")`.
    func callAsFunction(_ key: String) -> String { t(key) }

    static let strings: [String: [AppLanguage: String]] = [
        "airlift.move.mode": [.english: "AirLift move mode", .vietnamese: "Chế độ move AirLift"],
        "allow.risky.moves": [.english: "Allow risky moves", .vietnamese: "Cho phép thao tác nguy hiểm"],
        "app.groups": [.english: "App Groups", .vietnamese: "App Group"],
        "apply": [.english: "Apply", .vietnamese: "Áp dụng"],
        "apps": [.english: "Apps", .vietnamese: "Ứng dụng"],
        "cancel": [.english: "Cancel", .vietnamese: "Huỷ"],
        "catalog": [.english: "Catalog", .vietnamese: "Danh mục"],
        "clean.empty": [.english: "Clean empty", .vietnamese: "Dọn rỗng"],
        "clear": [.english: "Clear", .vietnamese: "Xoá"],
        "container.root": [.english: "Container root", .vietnamese: "Gốc container"],
        "copy.path": [.english: "Copy path", .vietnamese: "Sao chép đường dẫn"],
        "create": [.english: "Create", .vietnamese: "Tạo"],
        "data.container": [.english: "Data Container", .vietnamese: "Data Container"],
        "delete": [.english: "Delete", .vietnamese: "Xoá"],
        "delete.leftover.safe": [.english: "This leftover holds no data, so nothing is lost.", .vietnamese: "File tạm này không chứa dữ liệu, nên không mất gì."],
        "delete.leftover.warning": [.english: "This leftover CONTAINS DATA. Deleting it cannot be undone.", .vietnamese: "File tạm này CHỨA DỮ LIỆU. Xoá sẽ không khôi phục được."],
        "delete.pairing": [.english: "Delete Pairing Credentials", .vietnamese: "Xoá thông tin ghép nối"],
        "delete.permanently": [.english: "Delete permanently", .vietnamese: "Xoá vĩnh viễn"],
        "destination.folder": [.english: "destination folder (empty = container root)", .vietnamese: "thư mục đích (để trống = gốc container)"],
        "device.ip": [.english: "Device IP", .vietnamese: "IP thiết bị"],
        "done": [.english: "Done", .vietnamese: "Xong"],
        "empty.count": [.english: "empty", .vietnamese: "rỗng"],
        "empty.folder": [.english: "Empty folder", .vietnamese: "Thư mục rỗng"],
        "enable.risky.moves": [.english: "Enable risky moves?", .vietnamese: "Bật thao tác nguy hiểm?"],
        "enter.in.settings": [.english: "Enter in Settings › Privacy & Security › Developer Mode › Pair with Readipa", .vietnamese: "Nhập trong Cài đặt › Quyền riêng tư & Bảo mật › Chế độ nhà phát triển › Ghép nối với Readipa"],
        "export.as.zip": [.english: "Export as ZIP & Save", .vietnamese: "Xuất ZIP & Lưu"],
        "filter.logs": [.english: "Filter logs", .vietnamese: "Lọc nhật ký"],
        "filter.this.folder": [.english: "Filter this folder", .vietnamese: "Lọc thư mục này"],
        "folder": [.english: "Folder", .vietnamese: "Thư mục"],
        "folder.name": [.english: "Folder name", .vietnamese: "Tên thư mục"],
        "how.works": [.english: "How this works", .vietnamese: "Cách hoạt động"],
        "i.understand": [.english: "I understand", .vietnamese: "Tôi hiểu"],
        "icons": [.english: "App icons", .vietnamese: "Biểu tượng app"],
        "language": [.english: "Language", .vietnamese: "Ngôn ngữ"],
        "leftover": [.english: "Leftover", .vietnamese: "File tạm"],
        "live.activities.off": [.english: "Live Activities are off for Readipa, so the PIN stays on this screen only. Enable Settings › Readipa › Live Activities to keep it on the Lock Screen.", .vietnamese: "Live Activities đang tắt cho Readipa, nên mã PIN chỉ hiện trên màn hình này. Bật Cài đặt › Readipa › Live Activities để giữ trên Màn hình khoá."],
        "load.app.catalog": [.english: "Load App Catalog", .vietnamese: "Tải danh mục ứng dụng"],
        "loading": [.english: "Loading…", .vietnamese: "Đang tải…"],
        "logs": [.english: "Logs", .vietnamese: "Nhật ký"],
        "new.name": [.english: "New name", .vietnamese: "Tên mới"],
        "no.container": [.english: "This app has no data container", .vietnamese: "App này không có data container"],
        "no.match": [.english: "No match", .vietnamese: "Không khớp"],
        "not.paired": [.english: "Not paired", .vietnamese: "Chưa ghép"],
        "nothing.to.recover": [.english: "Nothing to recover", .vietnamese: "Không có gì để khôi phục"],
        "open": [.english: "Open", .vietnamese: "Mở"],
        "open.container.first": [.english: "Open a container from the Apps tab", .vietnamese: "Mở một container từ tab Ứng dụng"],
        "open.in.files": [.english: "Open in Files", .vietnamese: "Mở trong Tệp"],
        "paired": [.english: "Paired", .vietnamese: "Đã ghép"],
        "pairing": [.english: "Pairing", .vietnamese: "Ghép nối"],
        "pairing.failed": [.english: "Pairing failed", .vietnamese: "Ghép nối thất bại"],
        "pairing.succeeded": [.english: "Pairing succeeded", .vietnamese: "Ghép nối thành công"],
        "preview": [.english: "Preview", .vietnamese: "Xem trước"],
        "recovery": [.english: "Recovery", .vietnamese: "Khôi phục"],
        "refresh.icons": [.english: "Refresh app icons", .vietnamese: "Tải lại biểu tượng app"],
        "rename.or.move": [.english: "Rename or move", .vietnamese: "Đổi tên / di chuyển"],
        "replace": [.english: "Replace with file…", .vietnamese: "Thay bằng tệp…"],
        "restore": [.english: "Restore", .vietnamese: "Khôi phục"],
        "restore.into": [.english: "Restore into", .vietnamese: "Khôi phục vào"],
        "restore.leftover": [.english: "Restore leftover", .vietnamese: "Khôi phục file tạm"],
        "risky.moves.explain": [.english: "Containers that block direct access are only readable by temporarily moving a folder out of the app into /var/mobile/Media and back.\n\nReadipa verifies every move and always puts the folder back, and if anything goes wrong it tells you exactly where the data is kept — but for those seconds the app really is missing that folder.\n\nMoving live app data can also make iOS reclaim space afterwards (apps may lose their caches, and the device can behave oddly until it settles). Leave this OFF unless you really need to browse an App Group, and turn it back off when you are done.", .vietnamese: "Container chặn truy cập trực tiếp chỉ có thể đọc bằng cách tạm thời di chuyển thư mục ra /var/mobile/Media và đưa về.\n\nReadipa kiểm chứng mọi lần di chuyển và luôn đưa thư mục về, và nếu có lỗi sẽ cho biết chính xác dữ liệu ở đâu — nhưng trong vài giây đó app thực sự thiếu thư mục đó.\n\nDi chuyển dữ liệu app đang chạy còn có thể khiến iOS thu hồi dung lượng sau đó (các app có thể mất cache và máy có thể hoạt động bất thường cho tới khi ổn định). Hãy để TẮT trừ khi bạn thực sự cần xem App Group, và tắt lại khi xong."],
        "risky.moves.needed": [.english: "Needed only for containers that refuse both listing and reading. Read-only access never relocates anything.", .vietnamese: "Chỉ cần cho container từ chối cả liệt kê và đọc. Truy cập chỉ đọc không bao giờ di chuyển gì."],
        "risky.moves.on": [.english: "Risky moves are ON — folders may be relocated for a few seconds.", .vietnamese: "Đang BẬT thao tác nguy hiểm — thư mục có thể bị di chuyển vài giây."],
        "save": [.english: "Save", .vietnamese: "Lưu"],
        "scan": [.english: "Scan", .vietnamese: "Quét"],
        "search.apps": [.english: "Search apps or bundle id", .vietnamese: "Tìm app hoặc bundle id"],
        "search.groups": [.english: "Search groups or owner", .vietnamese: "Tìm group hoặc app sở hữu"],
        "setup": [.english: "Setup", .vietnamese: "Cài đặt"],
        "start.pairing": [.english: "Start Pairing", .vietnamese: "Bắt đầu ghép nối"],
        "status": [.english: "Status", .vietnamese: "Trạng thái"],
        "stored.in.documents.keychain": [.english: "Kept in Documents and the Keychain — relaunching keeps it.", .vietnamese: "Lưu trong Documents và Keychain — khởi động lại vẫn còn."],
        "tab.apps": [.english: "Apps", .vietnamese: "Ứng dụng"],
        "tab.files": [.english: "Files", .vietnamese: "Tệp"],
        "tab.logs": [.english: "Logs", .vietnamese: "Nhật ký"],
        "tab.setup": [.english: "Setup", .vietnamese: "Cài đặt"],
        "test.tunnel": [.english: "Test tunnel", .vietnamese: "Kiểm tra đường hầm"],
        "total": [.english: "total", .vietnamese: "tổng"],
        "tunnel": [.english: "Tunnel", .vietnamese: "Đường hầm"],
        "tunnel.checks": [.english: "Checks RSD (49152) and lockdownd (62078) on 10.7.0.1 and 192.168.1.2, plus this device's own addresses. Start the loopback VPN (LocalDevVPN / StosVPN) before pairing.", .vietnamese: "Kiểm tra RSD (49152) và lockdownd (62078) trên 10.7.0.1 và 192.168.1.2, cùng địa chỉ của chính máy này. Hãy bật VPN loopback (LocalDevVPN / StosVPN) trước khi ghép nối."],
        "type": [.english: "Type", .vietnamese: "Loại"],
        "version": [.english: "Version", .vietnamese: "Phiên bản"],
        "waiting.approve": [.english: "Waiting… approve the request in Settings", .vietnamese: "Đang chờ… hãy duyệt yêu cầu trong Cài đặt"],
        "with.data": [.english: "with data", .vietnamese: "có dữ liệu"],
    ]
}
