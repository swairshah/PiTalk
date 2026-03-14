import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var store: AppStore

    /// Programmatic navigation stack for deep linking.
    @State private var navigationPath = NavigationPath()
    /// Stable group key ordering — only mutated when groups are added/removed.
    @State private var groupOrder: [String] = []

    /// Sessions grouped by project key.
    private var groupedDict: [String: [RemoteSession]] {
        Dictionary(grouping: store.socket.snapshot.sessions) { session in
            session.project
                ?? session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? session.sourceApp
        }
    }

    /// Groups in stable order: existing groups keep position, new groups are appended.
    private var sortedGroups: [(key: String, sessions: [RemoteSession])] {
        let dict = groupedDict
        var result: [(key: String, sessions: [RemoteSession])] = []
        for key in groupOrder {
            if let sessions = dict[key] {
                result.append((key: key, sessions: sessions))
            }
        }
        // Append any brand-new keys not yet tracked.
        let tracked = Set(groupOrder)
        for key in dict.keys.sorted() where !tracked.contains(key) {
            if let sessions = dict[key] {
                result.append((key: key, sessions: sessions))
            }
        }
        return result
    }

    /// The set of current group keys — used to detect when groups are added/removed.
    private var currentGroupKeys: Set<String> {
        Set(groupedDict.keys)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                GradientBackground()

                VStack(alignment: .leading, spacing: 10) {
                    statusBar

                    if store.socket.snapshot.sessions.isEmpty {
                        EmptyStateView(
                            icon: "waveform",
                            title: "No active sessions",
                            subtitle: "Start a Pi session and it will appear here"
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(sortedGroups, id: \.key) { group in
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
                        .mask(ScrollFadeMask(topHeight: 8, bottomHeight: 16))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .navigationTitle("PiTalk")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { sessionId in
                SessionDetailView(sessionId: sessionId)
            }
            .onAppear { stabilizeGroupOrder() }
            .onChange(of: currentGroupKeys) { _, _ in stabilizeGroupOrder() }
            .onChange(of: store.deepLinkSessionId) { _, newValue in
                guard let sessionId = newValue else { return }
                store.deepLinkSessionId = nil
                // Pop to root then push the target session.
                navigationPath = NavigationPath()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    navigationPath.append(sessionId)
                }
            }
        }
    }

    /// Keep existing group positions; only insert new keys and prune dead ones.
    private func stabilizeGroupOrder() {
        let dict = groupedDict
        let liveKeys = Set(dict.keys)

        // Keep existing order, drop groups that disappeared.
        var updated = groupOrder.filter { liveKeys.contains($0) }

        // Append new groups sorted by most-recent-activity then alphabetically.
        let existing = Set(updated)
        let newKeys = liveKeys.subtracting(existing).sorted { a, b in
            let aLatest = dict[a]?.compactMap(\.lastSpokenAtMs).max() ?? 0
            let bLatest = dict[b]?.compactMap(\.lastSpokenAtMs).max() ?? 0
            if aLatest != bLatest { return aLatest > bLatest }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        updated.append(contentsOf: newKeys)

        if updated != groupOrder {
            groupOrder = updated
        }
    }

    /// Glass-styled status bar with connection info and metrics.
    private var statusBar: some View {
        HStack(spacing: 10) {
            if store.socket.connectionState == .connected {
                PulsingDot(color: .green)
            } else {
                Circle()
                    .fill(bannerColor)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 1) {
                if let profile = store.activeProfile {
                    Text(profile.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Text(bannerText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            let summary = store.socket.snapshot.summary
            HStack(spacing: 8) {
                MetricPill(value: summary.total, label: "S", tint: .secondary)
                if summary.speaking > 0 {
                    MetricPill(value: summary.speaking, label: "▶", tint: .red)
                }
                if summary.queued > 0 {
                    MetricPill(value: summary.queued, label: "◻", tint: .orange)
                }
            }

            if store.socket.connectionState == .connected {
                Button {
                    store.stopAll()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .modifier(GlassCircleModifier())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    store.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 32)
                        .modifier(GlassCircleModifier())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(GlassRectModifier(cornerRadius: 14))
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
        if sessions.contains(where: { $0.activity == "speaking" }) {
            return "speaking"
        }
        let precedence = ["starting", "thinking", "reading", "editing", "running", "searching", "error"]
        if let work = precedence.first(where: { status in sessions.contains(where: { $0.activity == status }) }) {
            return work
        }
        if sessions.contains(where: { $0.activity == "queued" }) {
            return "queued"
        }
        return "waiting"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if activityColor(groupActivity) == .red {
                        PulsingDot(color: .red)
                    } else {
                        Circle()
                            .fill(activityColor(groupActivity))
                            .frame(width: 8, height: 8)
                    }

                    Text(shortGroupKey(groupKey))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    StatusChip(
                        label: "\(sessions.count)",
                        color: .secondary
                    )

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
            .padding(.vertical, 10)

            if isExpanded {
                // Stable sort by pid so sessions don't jump around between polls.
                let stableSessions = sessions.sorted { ($0.pid ?? 0) < ($1.pid ?? 0) }
                VStack(spacing: 2) {
                    ForEach(stableSessions) { session in
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
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .modifier(GlassRectModifier(cornerRadius: 16))
    }

    private func shortGroupKey(_ raw: String) -> String {
        if raw.contains("/") {
            return raw.components(separatedBy: "/").last ?? raw
        }
        return raw
    }
}

// MARK: - Compact Session Row

private struct CompactSessionRow: View {
    let session: RemoteSession

    private var snippet: String? {
        session.currentText ?? session.lastSpokenText
    }

    /// Primary label: project name, mux, or sourceApp as fallback
    private var sessionLabel: String {
        if let project = session.project, !project.isEmpty {
            return project
        }
        if let mux = session.mux, !mux.isEmpty {
            return mux
        }
        return session.sourceApp
    }

    var body: some View {
        HStack(spacing: 8) {
            if session.activity == "speaking" {
                PulsingDot(color: activityColor(session.activity))
            } else {
                Circle()
                    .fill(activityColor(session.activity))
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sessionLabel)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if let pid = session.pid {
                        Text("pid \(pid)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }

                // Show status detail (e.g. "reading App.swift") or speech snippet
                if let detail = session.statusDetail, !detail.isEmpty,
                   isWorkActivity(session.activity) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let text = snippet {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            if session.queuedCount > 0 {
                StatusChip(label: "\(session.queuedCount)q", color: .orange)
            }

            StatusChip(
                label: session.activityLabel,
                color: activityColor(session.activity)
            )

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(GlassRectModifier(cornerRadius: 12))
    }
}
