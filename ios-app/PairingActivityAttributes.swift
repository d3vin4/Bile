import ActivityKit
import Foundation

struct PairingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var pin: String
        var status: String
    }
    var deviceName: String
}
