import ActivityKit
import Foundation

struct PairingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var pin: String
        var status: String
    }
    var deviceName: String
    /// UI language ("en" / "vi"). The widget extension runs in its own process
    /// and cannot read the app's UserDefaults, so the language travels with the
    /// activity attributes.
    var language: String = "en"
}
