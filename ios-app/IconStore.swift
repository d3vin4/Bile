import Foundation
import SwiftUI
import UIKit

/// Fetches and caches the real app icons from SpringBoard.
///
/// Icons land in the app's Caches directory, so they survive relaunches and are
/// only downloaded once per bundle id. Fetching is serialised to avoid opening a
/// tunnel per icon.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    @Published private(set) var images: [String: UIImage] = [:]
    private var pending: [String] = []
    private var running = false
    private var attempted: Set<String> = []

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheURL(_ bundleId: String) -> URL {
        let safe = bundleId.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent("\(safe).png")
    }

    func image(for bundleId: String) -> UIImage? { images[bundleId] }

    /// Loads from disk immediately; queues a device fetch when missing.
    func request(_ bundleId: String) {
        guard !bundleId.isEmpty else { return }
        if images[bundleId] != nil { return }
        if let cached = UIImage(contentsOfFile: cacheURL(bundleId).path) {
            images[bundleId] = cached
            return
        }
        if attempted.contains(bundleId) { return }
        if !pending.contains(bundleId) { pending.append(bundleId) }
        pump()
    }

    private func pump() {
        guard !running, let next = pending.first else { return }
        pending.removeFirst()
        running = true
        attempted.insert(next)

        let pairingPath = AppState.shared.pairingPath
        let dest = cacheURL(next).path
        Task.detached(priority: .utility) { [next, dest, pairingPath] in
            var succeeded = false
            do {
                try RustBridge.appIcon(pairingPath: pairingPath, bundleId: next, destLocalPath: dest)
                succeeded = true
            } catch {
                // Silent: the generated avatar stays as the fallback.
            }
            let ok = succeeded
            await MainActor.run {
                IconStore.shared.finish(bundleId: next, path: dest, succeeded: ok)
            }
        }
    }

    fileprivate func finish(bundleId: String, path: String, succeeded: Bool) {
        if succeeded, let img = UIImage(contentsOfFile: path) {
            images[bundleId] = img
        }
        running = false
        pump()
    }

    func clearCache() {
        images.removeAll()
        attempted.removeAll()
        pending.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

/// App icon view: the real icon when available, otherwise a generated avatar.
struct AppIconView: View {
    let bundleId: String
    let name: String
    let size: CGFloat
    @ObservedObject private var store = IconStore.shared

    init(bundleId: String, name: String, size: CGFloat = 40) {
        self.bundleId = bundleId
        self.name = name
        self.size = size
    }

    var body: some View {
        let radius = size * 0.22
        Group {
            if let image = store.image(for: bundleId) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                GeneratedIcon(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .onAppear { store.request(bundleId) }
    }
}

/// Deterministic gradient avatar used until the real icon arrives.
struct GeneratedIcon: View {
    let name: String
    let size: CGFloat

    private var colors: [Color] {
        // Stable hue per app name.
        var hash: UInt64 = 5381
        for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let hue = Double(hash % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.62, brightness: 0.95),
            Color(hue: hue, saturation: 0.78, brightness: 0.68)
        ]
    }

    var body: some View {
        let letter = String(name.prefix(1)).uppercased()
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                Text(letter)
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}
