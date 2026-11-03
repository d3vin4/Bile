import ActivityKit
import SwiftUI
import WidgetKit

/// Tiny helper so the Live Activity follows the in-app language picker.
private struct L {
    let vi: Bool
    init(_ context: ActivityViewContext<PairingActivityAttributes>) {
        vi = context.attributes.language == "vi"
    }
    func t(_ en: String, _ vietnamese: String) -> String { vi ? vietnamese : en }
}

struct PairingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PairingActivityAttributes.self) { context in
            // Lock Screen / banner UI
            let l = L(context)
            VStack(alignment: .leading, spacing: 8) {
                Text(l.t(
                    "Pairing with \(context.attributes.deviceName)",
                    "Đang ghép đôi với \(context.attributes.deviceName)"
                ))
                .font(.headline)
                Text(l.t(
                    "Enter this PIN in Settings › Developer Mode:",
                    "Nhập mã PIN này trong Cài đặt › Developer Mode:"
                ))
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
            let l = L(context)
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(l.t("PIN", "Mã PIN"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.pin).font(.title2.bold().monospaced())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        // Big enough to read upside-down from the PIN prompt.
                        Text(context.state.pin)
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                            .foregroundStyle(.blue)
                        Text(context.state.status)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
