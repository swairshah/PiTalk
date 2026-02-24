import ActivityKit
import SwiftUI
import WidgetKit

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
                            .foregroundStyle(.orange)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.projectName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.green)
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
            // Header row: agent + project + status
            HStack(spacing: 8) {
                activityDot(state.activity)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 1) {
                    Text(attrs.agentName)
                        .font(.subheadline.bold())
                    Text(attrs.projectName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.activityLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(activityColor(state.activity))

                    if state.queuedCount > 0 {
                        Text("\(state.queuedCount) queued")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Speech content
            if state.isFinished {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                    Text(state.lastSpokenText ?? "Done")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } else if let text = state.currentText {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            // Footer: server name
            HStack {
                Image(systemName: "server.rack")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(attrs.serverName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .padding(14)
        .activitySystemActionForegroundColor(.primary)
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
        case "speaking", "running": return .red
        case "queued": return .orange
        case "waiting": return .green
        default: return .gray
        }
    }
}
