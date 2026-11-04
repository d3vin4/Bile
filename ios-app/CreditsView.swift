import SwiftUI

/// Credits: who made Bile. App icon, quick about, GitHub profile + avatar.
struct CreditsView: View {
    @EnvironmentObject var lang: LanguageManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentIcon: String? = UIApplication.shared.alternateIconName
    @State private var switchingIcon = false
    @State private var iconError: String? = nil

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

                    // App icon switcher
                    VStack(spacing: 10) {
                        Text(lang("credits.icon"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 12) {
                            iconOption(alternateName: nil, title: lang("icon.default"))
                            iconOption(alternateName: "AltBlue", title: lang("icon.blue"))
                        }
                        if switchingIcon {
                            HStack(spacing: 6) {
                                ProgressView()
                                Text(lang("icon.changing"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let iconError {
                            Text(iconError)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
                    .padding(.horizontal, 20)

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

    // MARK: - Icon switcher

    private func iconOption(alternateName: String?, title: String) -> some View {
        let active = currentIcon == alternateName
        return Button {
            switchIcon(to: alternateName)
        } label: {
            VStack(spacing: 6) {
                iconPreview(for: alternateName)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if active {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body)
                                .foregroundStyle(.blue, .white)
                                .offset(x: 6, y: -6)
                        }
                    }
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? Color.blue.opacity(0.12) : Color(uiColor: .tertiarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(active ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(switchingIcon || active)
    }

    @ViewBuilder
    private func iconPreview(for alternateName: String?) -> some View {
        if alternateName == nil, let icon = appIcon {
            Image(uiImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else if let name = alternateName,
                  let url = Bundle.main.url(forResource: name + "@3x", withExtension: "png"),
                  let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.gray.opacity(0.3))
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func switchIcon(to alternateName: String?) {
        guard alternateName != currentIcon, !switchingIcon else { return }
        switchingIcon = true
        iconError = nil
        UIApplication.shared.setAlternateIconName(alternateName) { error in
            DispatchQueue.main.async {
                switchingIcon = false
                if let error {
                    iconError = error.localizedDescription
                } else {
                    currentIcon = alternateName
                }
            }
        }
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
