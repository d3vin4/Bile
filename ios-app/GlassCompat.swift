import SwiftUI

// Liquid Glass (iOS 26) with a functional fallback for earlier releases.
// Every effect is applied *after* layout/appearance modifiers, and grouping is
// left to GlassEffectContainer at the call site so shapes blend correctly.

extension View {
    /// Glass card background for a content grouping.
    @ViewBuilder
    func readipaGlassCard(cornerRadius: CGFloat = 16) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    /// Capsule glass, for compact status chips.
    @ViewBuilder
    func readipaGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// Standard / prominent glass button style.
    @ViewBuilder
    func readipaGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

/// Small labelled status chip used across Setup / Files.
struct StatusChip: View {
    let title: String
    let value: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption).bold()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .readipaGlassCapsule()
    }
}
