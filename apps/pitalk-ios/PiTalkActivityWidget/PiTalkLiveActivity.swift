import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Warm palette for widget (matches icon: browns, terra cotta, gold)

private let warmGreen   = Color(red: 0.36, green: 0.49, blue: 0.24) // #5B7D3E olive
private let warmRed     = Color(red: 0.69, green: 0.23, blue: 0.18) // #B03A2E brick
private let warmAmber   = Color(red: 0.75, green: 0.48, blue: 0.10) // #C07A1A gold
private let warmTerra   = Color(red: 0.65, green: 0.29, blue: 0.18) // #A5492E terra cotta
private let warmGray    = Color(red: 0.66, green: 0.58, blue: 0.52) // #A89585 warm muted
private let dimWarm     = Color(red: 0.48, green: 0.43, blue: 0.40) // #7A6E65 warm dim

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
                            .foregroundStyle(warmAmber)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.projectName)
                        .font(.caption)
                        .foregroundStyle(warmGray)
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
                        .foregroundStyle(warmGreen)
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
                        .foregroundStyle(warmGray)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    statusChip(state.activityLabel, color: activityColor(state.activity))

                    if state.queuedCount > 0 {
                        Text("\(state.queuedCount) queued")
                            .font(.caption2)
                            .foregroundStyle(warmAmber)
                    }
                }
            }

            // Speech content
            if state.isFinished {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(warmGreen)
                        .font(.callout)
                    Text(state.lastSpokenText ?? "Done")
                        .font(.callout)
                        .foregroundStyle(warmGray)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else if let text = state.currentText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundStyle(warmGray)
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
                        .foregroundStyle(dimWarm)
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(warmGray)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            // Footer
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 9))
                    .foregroundStyle(dimWarm)
                Text(attrs.serverName)
                    .font(.caption2)
                    .foregroundStyle(dimWarm)
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
        case "speaking", "error": return warmRed
        case "starting": return warmGreen
        case "thinking", "running", "queued": return warmAmber
        case "reading": return warmTerra
        case "editing": return warmAmber
        case "searching": return warmAmber
        case "waiting": return warmGreen
        default: return warmGray
        }
    }
}
