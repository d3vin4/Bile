import SwiftUI

/// Credits — Basic dark layout: app info on top, author below.
/// No glass, no blur, no translucency — plain Form on the system background.
struct CreditsView: View {
    @EnvironmentObject var lang: LanguageManager
    @Environment(\.dismiss) private var dismiss

    private let githubUser = "d3vin4"
    private var profileURL: URL { URL(string: "https://github.com/\(githubUser)")! }
    private var repoURL: URL { URL(string: "https://github.com/\(githubUser)/Bile")! }
    private var avatarURL: URL { URL(string: "https://github.com/\(githubUser).png")! }

    private var appIcon: UIImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    var body: some View {
        NavigationView {
            Form {
                // App information — above the author.
                Section {
                    VStack(spacing: 10) {
                        if let icon = appIcon {
                            Image(uiImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 88, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        VStack(spacing: 2) {
                            Text("Bile")
                                .font(.title2.bold())
                            Text(versionLine)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                // Author.
                Section(lang("credits.author")) {
                    HStack(spacing: 12) {
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
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(lang("credits.author"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("@\(githubUser)")
                                .font(.body.monospaced())
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)

                    Link(destination: profileURL) {
                        Label(lang("credits.profile"), systemImage: "person.crop.circle")
                    }
                    Link(destination: repoURL) {
                        Label(lang("credits.repo"), systemImage: "shippingbox")
                    }
                }
            }
            .navigationTitle(lang("credits"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lang("done")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }

    private var versionLine: String {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(marketing) (\(build))"
    }
}
