import SwiftUI

/// Start-up warning about the *data-loss* risk of using the app.
///
/// Swiping to the second page switches the whole app to Vietnamese (and back).
/// The user must tap “I understand”; the small switch remembers not to show it
/// again on the next launch.
struct LaunchGateView: View {
    @EnvironmentObject var lang: LanguageManager
    /// Called when the user accepts the warning.
    let onAccept: () -> Void

    @State private var page: Int
    @State private var remaining = 5
    @State private var dontShowAgain = UserDefaults.standard.bool(forKey: LaunchGateView.skipKey)

    static let skipKey = "readipa.skipLaunchWarning"

    init(onAccept: @escaping () -> Void) {
        self.onAccept = onAccept
        let initial = LanguageManager.shared.language == .vietnamese ? 1 : 0
        _page = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                warningPage(for: .english).tag(0)
                warningPage(for: .vietnamese).tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .onChange(of: page) { _, newValue in
                lang.language = (newValue == 1) ? .vietnamese : .english
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task {
            for value in (1...5).reversed() {
                remaining = value
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            remaining = 0
        }
    }

    private func warningPage(for language: AppLanguage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Readipa").font(.largeTitle.bold())
                        Text(text("gate.title", language))
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
                }

                Text(text("gate.lead", language))
                    .font(.callout)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(["gate.b1", "gate.b2", "gate.b3", "gate.b4", "gate.b5"], id: \.self) { key in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5))
                                .padding(.top, 6)
                                .foregroundStyle(.secondary)
                            Text(text(key, language))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
                .readipaGlassCard(cornerRadius: 14)

                Label(text("gate.backup", language), systemImage: "externaldrive.badge.checkmark")
                    .font(.callout.bold())
                    .foregroundStyle(.red)

                Divider().padding(.vertical, 4)

                Toggle(text("gate.dontshow", language), isOn: $dontShowAgain)
                    .font(.footnote)

                if remaining > 0 {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("\(text("gate.waiting", language)) \(remaining)s")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    if dontShowAgain {
                        UserDefaults.standard.set(true, forKey: LaunchGateView.skipKey)
                    } else {
                        UserDefaults.standard.set(false, forKey: LaunchGateView.skipKey)
                    }
                    onAccept()
                } label: {
                    Text(text("gate.understand", language))
                        .frame(maxWidth: .infinity)
                }
                .readipaGlassButton(prominent: true)
                .disabled(remaining > 0)

                HStack {
                    Spacer()
                    Label(text("gate.swipe", language), systemImage: "arrow.left.arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.top, 4)
            }
            .padding(22)
        }
    }

    /// Reads the string for a *specific* language, so both pages stay readable
    /// whichever language is currently active.
    private func text(_ key: String, _ language: AppLanguage) -> String {
        LanguageManager.strings[key]?[language] ?? key
    }
}
