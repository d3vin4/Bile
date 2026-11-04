import SwiftUI

/// Credits: app icon, version, author. Minimal, Liquid Glass.
struct CreditsView: View {
    @EnvironmentObject var lang: LanguageManager
    @Environment(\.dismiss) private var dismiss

    private let githubUser = "d3vin4"
    private var profileURL: URL { URL(string: "https://github.com/\(githubUser)")! }
    private var repoURL: URL { URL(string: "https://github.com/\(githubUser)/Bile")! }
    private var avatarURL: URL { URL(string: "https://github.com/\(githubUser).png")! }

    private var appIcon: UIImage? {
        // The real catalog icon — never a placeholder letter.
        guard let path = Bundle.main.url(forResource: "AppIcon", withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: path.path)
            ?? Bundle.main.appIcon
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // App identity — the genuine icon, glass-framed.
                    VStack(spacing: 10) {
                        if let icon = appIcon {
                            Image(uiImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                                .readipaGlassCard(cornerRadius: 22)
                                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                        }
                        Text("Bile")
                            .font(.title.bold())
                        Text(versionLine)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)

                    // Author — avatar beside the handle, one glass card.
                    HStack(spacing: 14) {
                        AsyncImage(url: avatarURL) { phase in
                            if let image = phase.image {
                                image.resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Circle().fill(Color.blue.opacity(0.25))
                                    .overlay { ProgressView() }
                            }
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text(lang("credits.author"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("@\(githubUser)")
                                .font(.headline.monospaced())
                            HStack(spacing: 14) {
                                Link(destination: profileURL) {
                                    Label(lang("credits.profile"), systemImage: "person.crop.circle")
                                        .font(.caption.bold())
                                }
                                Link(destination: repoURL) {
                                    Label(lang("credits.repo"), systemImage: "shippingbox")
                                        .font(.caption.bold())
                                }
                            }
                        }
                    }
                    .padding(16)
                    .readipaGlassCard(cornerRadius: 18)
                    .padding(.horizontal, 24)

                    Text(lang("credits.license"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(lang("credits"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang("done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var versionLine: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(marketing) (\(build))"
    }
}

// MARK: - Bundle app icon

private extension Bundle {
    /// The app's own icon image, read back from the bundle by name.
    var appIcon: UIImage? {
        guard let iconName = object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = iconName["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else {
            return nil
        }
        let candidates = ["\(last)@3x.png", "\(last)@2x.png", "\(last).png", last]
        for name in candidates {
            if let url = url(forResource: name, withExtension: nil),
               let image = UIImage(contentsOfFile: url.path) {
                return image
            }
        }
        return nil
    }
}
