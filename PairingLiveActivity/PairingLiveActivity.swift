import ActivityKit
import SwiftUI
import WidgetKit

struct PairingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            // Lock Screen / banner UI
            VStack(alignment: .leading, spacing: 8) {
                Text("Pairing with \(context.attributes.deviceName)")
                    .font(.headline)
                Text("Enter this PIN in Settings › Developer Mode:")
                    .font(.caption)
                Text(context.state.pin)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundStyle(.blue)
                Text(context.state.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.8))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("PIN").font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.pin).font(.title2.bold().monospaced())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.status).font(.caption2)
                }
            } compactLeading: {
                Image(systemName: "lock.shield")
            } compactTrailing: {
                Text(context.state.pin).font(.caption.bold().monospaced())
            } minimal: {
                Image(systemName: "lock.shield")
            }
        }
    }
}

@main
struct PairingLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        PairingLiveActivityWidget()
    }
}
