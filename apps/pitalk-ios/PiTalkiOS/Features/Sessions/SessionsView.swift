import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var store: AppStore

    /// Sessions grouped by project, sorted by most recent activity (latest first).
    private var groupedSessions: [(key: String, sessions: [RemoteSession])] {
        let dict = Dictionary(grouping: store.socket.snapshot.sessions) { session in
            session.sessionId ?? session.cwd ?? session.sourceApp
        }
        return dict.map { (key: $0.key, sessions: $0.value) }
            .sorted { a, b in
                let aLatest = a.sessions.compactMap(\.lastSpokenAtMs).max() ?? 0
                let bLatest = b.sessions.compactMap(\.lastSpokenAtMs).max() ?? 0
                return aLatest > bLatest
            }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                // Compact status bar: connection + metrics in one row
                statusBar

                if store.socket.snapshot.sessions.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(groupedSessions, id: \.key) { group in
                                SessionGroupSection(
                                    groupKey: group.key,
                                    sessions: group.sessions,
                                    onSelect: { session in
                                        store.selectedSessionId = session.id
                                    }
                                )
                            }
                        }
                        .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .navigationTitle("PiTalk")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { sessionId in
                SessionDetailView(sessionId: sessionId)
            }
        }
    }

    /// Single compact row: connection dot + status text + metrics + stop/reconnect
    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(bannerColor)
                .frame(width: 8, height: 8)

            Text(bannerText)
                .font(.caption.weight(.medium))
                .lineLimit(1)

            Spacer(minLength: 4)

            let summary = store.socket.snapshot.summary
            HStack(spacing: 8) {
                metricPill(value: summary.total, label: "S", tint: .secondary)
                if summary.speaking > 0 {
                    metricPill(value: summary.speaking, label: "▶", tint: .red)
                }
                if summary.queued > 0 {
                    metricPill(value: summary.queued, label: "◻", tint: .orange)
                }
            }

            if store.socket.connectionState == .connected {
                Button {
                    store.stopAll()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
            } else {
                Button {
                    store.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func metricPill(value: Int, label: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No active sessions")
                .foregroundStyle(.secondary)
            Text("Start a Pi session and it will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 40)
    }

    private var bannerText: String {
        switch store.socket.connectionState {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }

    private var bannerColor: Color {
        switch store.socket.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .failed, .idle: return .red
        }
    }
}

// MARK: - Session Group

/// A collapsible section that groups sessions by project.
private struct SessionGroupSection: View {
    let groupKey: String
    let sessions: [RemoteSession]
    let onSelect: (RemoteSession) -> Void

    @State private var isExpanded: Bool = true

    private var groupActivity: String {
        if sessions.contains(where: { $0.activity == "speaking" || $0.activity == "running" }) {
            return "speaking"
        }
        if sessions.contains(where: { $0.activity == "queued" }) {
            return "queued"
        }
        return "waiting"
    }

    private var latestSnippet: String? {
        sessions.compactMap { $0.currentText ?? $0.lastSpokenText }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(activityColor(groupActivity))
                        .frame(width: 8, height: 8)
                    Text(shortGroupKey(groupKey))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(sessions.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let snippet = latestSnippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(sessions) { session in
                        NavigationLink(value: session.id) {
                            CompactSessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            onSelect(session)
                        })
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func shortGroupKey(_ raw: String) -> String {
        if raw.contains("/") {
            return raw.components(separatedBy: "/").last ?? raw
        }
        return raw
    }

    private func activityColor(_ activity: String) -> Color {
        switch activity {
        case "speaking", "running": return .red
        case "queued": return .orange
        case "waiting": return .green
        default: return .secondary
        }
    }
}

// MARK: - Compact Session Row

private struct CompactSessionRow: View {
    let session: RemoteSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(activityColor(session.activity))
                .frame(width: 6, height: 6)

            if let mux = session.mux, !mux.isEmpty {
                Text(mux)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            } else {
                Text(session.sourceApp)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }

            if let pid = session.pid {
                Text("pid \(pid)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            if session.queuedCount > 0 {
                Text("\(session.queuedCount)q")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
            }

            Text(session.activityLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func activityColor(_ activity: String) -> Color {
        switch activity {
        case "speaking", "running": return .red
        case "queued": return .orange
        case "waiting": return .green
        default: return .secondary
        }
    }
}
