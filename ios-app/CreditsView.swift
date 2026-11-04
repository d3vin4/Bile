import SwiftUI

/// Credits: who made Bile. App icon, quick about, GitHub profile + avatar.
struct CreditsView: View {
    @EnvironmentObject var lang: LanguageManager
    @Environment(\.dismiss) private var dismiss

    private let githubUser = "d3vin4"
    private var profileURL: URL { URL(string: "https://github.com/\(githubUser)")! }
    private var avatarURL: URL { URL(string: "https://github.com/\(githubUser).png")! }
    private var repoURL: URL { URL(string: "https://github.com/\(githubUser)/Bile")! }

    private var appIcon: UIImage? { UIImage(named: "AppIcon") }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    // App identity
                    VStack(spacing: 10) {
                        iconView
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                        VStack(spacing: 2) {
                            Text("Bile")
                                .font(.title.bold())
                            Text(versionLine)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)

                    Text(lang("credits.about"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 34)

                    // Author card: avatar beside the handle.
                    HStack(spacing: 14) {
                        AsyncImage(url: avatarURL) { phase in
                            if let image = phase.image {
                                image.resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Circle()
                                    .fill(Color.blue.opacity(0.25))
                                    .overlay { ProgressView() }
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(lang("credits.author"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("@\(githubUser)")
                                .font(.headline.monospaced())
                            HStack(spacing: 10) {
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
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                    .padding(.horizontal, 20)

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

    @ViewBuilder
    private var iconView: some View {
        if let icon = appIcon {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color.blue, Color.indigo],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                Text("B")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}
