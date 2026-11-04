import SwiftUI

/// Credits: who made Bile. GitHub profile + avatar, front and center.
struct CreditsView: View {
    @EnvironmentObject var lang: LanguageManager
    @Environment(\.dismiss) private var dismiss

    private let githubUser = "d3vin4"
    private var profileURL: URL { URL(string: "https://github.com/\(githubUser)")! }
    private var avatarURL: URL { URL(string: "https://github.com/\(githubUser).png")! }

    var body: some View {
        NavigationView {
            VStack(spacing: 22) {
                Spacer(minLength: 8)

                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    Text("Bile")
                        .font(.largeTitle.bold())
                    Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.horizontal, 40)

                // Author: avatar next to the GitHub handle.
                VStack(spacing: 12) {
                    AsyncImage(url: avatarURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Circle()
                                .fill(Color.accentColor.opacity(0.25))
                                .overlay {
                                    ProgressView()
                                }
                        }
                    }
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                    HStack(spacing: 8) {
                        Text("@\(githubUser)")
                            .font(.headline.monospaced())
                        Link(destination: profileURL) {
                            Image(systemName: "arrow.up.right.square.fill")
                                .font(.body)
                        }
                    }

                    Link(destination: profileURL) {
                        Label("github.com/\(githubUser)", systemImage: "link")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
}
