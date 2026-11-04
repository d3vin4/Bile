import SwiftUI

// Bile uses the native iOS Liquid Glass surfaces as-is (system toolbars,
// tab bar, menus). This file only carries the shared dark-gray palette and
// the canvas helper that keeps every screen on the same background.

// MARK: - Bile dark gray surfaces (Facebook Dark Mode palette)

extension Color {
    /// Main canvas — #18191A, never pure black.
    static let bileBackground = Color(red: 0.0941, green: 0.0980, blue: 0.1020)
    /// Bars, cards and secondary surfaces — #242526.
    static let bileSurface = Color(red: 0.1412, green: 0.1451, blue: 0.1490)
    /// Pressed / elevated states — #3A3B3C.
    static let bileElevated = Color(red: 0.2275, green: 0.2314, blue: 0.2353)
    /// Subtle separators — #3E4042 at low opacity.
    static let bileSeparator = Color(red: 0.2431, green: 0.2510, blue: 0.2588).opacity(0.55)
}

extension View {
    /// Shared canvas: hides the system list/editor background (pure black in
    /// dark mode) and lays the Facebook-style dark gray underneath, safe areas
    /// included.
    func bileCanvas() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Color.bileBackground.ignoresSafeArea())
    }
}
