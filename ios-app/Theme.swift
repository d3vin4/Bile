import SwiftUI

/// Centralized colour system — every surface, text and accent in Bile comes
/// from here. Views must not hardcode their own backgrounds or accents.
///
/// Surfaces follow the Facebook Dark Mode grays; text is white over a light
/// gray; the single accent is white. `preferredColorScheme(.dark)` at the app
/// root keeps every screen (and every system control) inside this palette.
enum BileTheme {

    // MARK: Surfaces

    /// Main canvas — #18191A, never pure black.
    static let background = Color.bileBackground
    /// Bars, cards and secondary surfaces — #242526.
    static let surface = Color.bileSurface
    /// Pressed / elevated states — #3A3B3C.
    static let elevated = Color.bileElevated
    /// Subtle separators — #3E4042 at low opacity.
    static let separator = Color.bileSeparator

    // MARK: Text

    /// Primary text — white.
    static let textPrimary = Color.white
    /// Secondary text — bright gray #B0B3B8.
    static let textSecondary = Color(red: 0.6902, green: 0.7020, blue: 0.7216)

    // MARK: Accent & interaction

    /// The one app-wide accent (buttons, toolbar, selection): white on the
    /// dark gray canvas.
    static let tint = Color.white
    /// Symlinks keep a distinct marker colour.
    static let link = Color.white

    // MARK: Row backgrounds

    /// Background painted behind rows of plain lists (same as the canvas so
    /// rows can never flash pure black, whatever the system does).
    static let rowBackground = Color.bileBackground
    /// Background painted behind Form rows (a step up from the canvas).
    static let cardRowBackground = Color.bileSurface
}
