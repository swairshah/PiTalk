import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Muted palette for widget (can't use PT since it's a separate target)

private let mutedGreen  = Color(red: 0.18, green: 0.49, blue: 0.20) // #2E7D32
private let mutedRed    = Color(red: 0.83, green: 0.18, blue: 0.18) // #D32F2F
private let mutedAmber  = Color(red: 0.90, green: 0.32, blue: 0.00) // #E65100
private let mutedCyan   = Color(red: 0.00, green: 0.52, blue: 0.74) // #0184BC
private let mutedGray   = Color(white: 0.55)                         // muted text
private let dimGray     = Color(white: 0.40)                         // tertiary

struct PiTalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PiTalkActivityAttributes.self) { context in
            lockScreenBanner(context: context)
                .widgetURL(deepLink(for: context.attributes.sessionKey))
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        activityDot(context.state.activity)
                            .frame(width: 8, height: 8)
                        Text(context.attributes.agentName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.queuedCount > 0 {
                        Text("\(context.state.queuedCount) queued")
                            .font(.caption2)
                            .foregroundStyle(mutedAmber)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.projectName)
                        .font(.caption)
                        .foregroundStyle(mutedGray)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let text = context.state.currentText ?? context.state.lastSpokenText {
                        Text(text)
                            .font(.callout)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } compactLeading: {
                activityDot(context.state.activity)
                    .frame(width: 6, height: 6)
            } compactTrailing: {
                if context.state.isFinished {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                        .foregroundStyle(mutedGreen)
                } else {
                    Text(context.attributes.projectName)
                        .font(.caption2)
                        .lineLimit(1)
                        .frame(maxWidth: 72)
                }
            } minimal: {
                activityDot(context.state.activity)
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Lock Screen Banner

    @ViewBuilder
    private func lockScreenBanner(context: ActivityViewContext<PiTalkActivityAttributes>) -> some View {
        let state = context.state
        let attrs = context.attributes

        VStack(alignment: .leading, spacing: 6) {
            // Header row
            HStack(spacing: 8) {
                activityDot(state.activity)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text(attrs.agentName)
                        .font(.subheadline.bold())
                    Text(attrs.projectName)
                        .font(.caption2)
                        .foregroundStyle(mutedGray)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    statusChip(state.activityLabel, color: activityColor(state.activity))

                    if state.queuedCount > 0 {
                        Text("\(state.queuedCount) queued")
                            .font(.caption2)
                            .foregroundStyle(mutedAmber)
                    }
                }
            }

            // Speech content
            if state.isFinished {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(mutedGreen)
                        .font(.callout)
                    Text(state.lastSpokenText ?? "Done")
                        .font(.callout)
                        .foregroundStyle(mutedGray)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else if let text = state.currentText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundStyle(mutedGray)
                    Text(text)
                        .font(.callout)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else if let text = state.lastSpokenText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundStyle(dimGray)
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(mutedGray)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            // Footer
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 9))
                    .foregroundStyle(dimGray)
                Text(attrs.serverName)
                    .font(.caption2)
                    .foregroundStyle(dimGray)
                Spacer()
            }
        }
        .padding(14)
        .activitySystemActionForegroundColor(.primary)
    }

    // MARK: - Components

    private func statusChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Deep Link

    private func deepLink(for sessionKey: String) -> URL {
        let encoded = sessionKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionKey
        return URL(string: "pitalk://session/\(encoded)")!
    }

    // MARK: - Helpers

    @ViewBuilder
    private func activityDot(_ activity: String) -> some View {
        Circle()
            .fill(activityColor(activity))
    }

    private func activityColor(_ activity: String) -> Color {
        switch activity {
        case "speaking", "error": return mutedRed
        case "starting": return mutedGreen
        case "thinking", "running", "queued": return mutedAmber
        case "reading": return mutedCyan
        case "editing": return mutedAmber
        case "searching": return mutedAmber
        case "waiting": return mutedGreen
        default: return mutedGray
        }
    }
}
