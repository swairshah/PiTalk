import SwiftUI

@main
struct PiTalkiOSApp: App {
    @StateObject private var store = AppStore()
    @AppStorage("pitalk.appearance") private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(store)
                .preferredColorScheme(appearance.colorScheme)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "pitalk", url.host == "session" else { return }
        let sessionKey = url.pathComponents.dropFirst().joined(separator: "/")
        guard !sessionKey.isEmpty else { return }
        store.deepLinkSessionId = sessionKey
        store.selectedSessionId = sessionKey
    }
}

/// User-selectable appearance mode.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Main View

struct MainView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        ZStack {
            GradientBackground()

            if store.selectedSessionId != nil,
               let sessionId = store.selectedSessionId,
               store.socket.snapshot.sessions.contains(where: { $0.id == sessionId }) {
                SessionFullScreen(
                    sessionId: sessionId,
                    onBack: { store.selectedSessionId = nil },
                    onSettings: { showSettings = true }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                SessionsHomeView(onSettings: { showSettings = true })
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.88), value: store.selectedSessionId)
        .onAppear {
            if let profile = store.activeProfile {
                store.connectToProfile(profile)
            }
        }
        .onChange(of: scenePhase) { _, phase in store.handleScenePhase(phase) }
        .onChange(of: store.deepLinkSessionId) { _, newValue in
            guard let sessionId = newValue else { return }
            store.deepLinkSessionId = nil
            store.selectedSessionId = sessionId
        }
        .sheet(isPresented: $showSettings) {
            RemoteSettingsView().environmentObject(store)
        }
    }
}

// MARK: - Sessions Home

private struct SessionsHomeView: View {
    @EnvironmentObject private var store: AppStore
    let onSettings: () -> Void
    @State private var groupOrder: [String] = []

    private var groupedDict: [String: [RemoteSession]] {
        Dictionary(grouping: store.socket.snapshot.sessions) { s in
            s.project
                ?? s.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? s.sourceApp
        }
    }

    private var sortedGroups: [(key: String, sessions: [RemoteSession])] {
        let dict = groupedDict
        var result: [(key: String, sessions: [RemoteSession])] = []
        for key in groupOrder {
            if let s = dict[key] { result.append((key: key, sessions: s)) }
        }
        let tracked = Set(groupOrder)
        for key in dict.keys.sorted() where !tracked.contains(key) {
            if let s = dict[key] { result.append((key: key, sessions: s)) }
        }
        return result
    }

    private var currentGroupKeys: Set<String> { Set(groupedDict.keys) }

    var body: some View {
        VStack(spacing: 0) {
            homeHeader.padding(.bottom, 4)

            if store.socket.snapshot.sessions.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(sortedGroups, id: \.key) { group in
                            SessionGroupCard(
                                groupKey: group.key,
                                sessions: group.sessions,
                                onSelect: { store.selectedSessionId = $0.id }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 20)
                }
                .mask(ScrollFadeMask(topHeight: 8, bottomHeight: 20))
            }
        }
        .onAppear { stabilizeGroupOrder() }
        .onChange(of: currentGroupKeys) { _, _ in stabilizeGroupOrder() }
    }

    private func stabilizeGroupOrder() {
        let dict = groupedDict
        let liveKeys = Set(dict.keys)
        var updated = groupOrder.filter { liveKeys.contains($0) }
        let newKeys = liveKeys.subtracting(Set(updated)).sorted { a, b in
            let aL = dict[a]?.compactMap(\.lastSpokenAtMs).max() ?? 0
            let bL = dict[b]?.compactMap(\.lastSpokenAtMs).max() ?? 0
            if aL != bL { return aL > bL }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        updated.append(contentsOf: newKeys)
        if updated != groupOrder { groupOrder = updated }
    }

    private var homeHeader: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image("BrandIcon")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    if let profile = store.activeProfile {
                        Text(profile.displayName)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(PT.textSecondary)
                    }
                }
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "gear")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(PT.textSecondary)
                        .frame(width: 36, height: 36)
                        .modifier(GlassCircleModifier())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)

            statusBar.padding(.horizontal, 16)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if store.socket.connectionState == .connected {
                PulsingDot(color: PT.green)
            } else {
                Circle().fill(bannerColor).frame(width: 8, height: 8)
            }

            Text(bannerText)
                .font(.caption.weight(.medium))
                .foregroundStyle(PT.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            let summary = store.socket.snapshot.summary
            HStack(spacing: 8) {
                if summary.total > 0 {
                    MetricPill(value: summary.total, label: "S", tint: PT.textMuted)
                }
                if summary.speaking > 0 {
                    MetricPill(value: summary.speaking, label: "▶", tint: PT.red)
                }
                if summary.queued > 0 {
                    MetricPill(value: summary.queued, label: "◻", tint: PT.orange)
                }
            }

            if store.socket.connectionState == .connected {
                Button { store.stopAll() } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption2)
                        .foregroundStyle(PT.textMuted)
                        .frame(width: 30, height: 30)
                        .modifier(GlassCircleModifier())
                }
                .buttonStyle(.plain)
            } else {
                Button { store.reconnect() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(PT.accent)
                        .frame(width: 30, height: 30)
                        .modifier(GlassCircleModifier())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(GlassRectModifier(cornerRadius: 14))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 56))
                .foregroundStyle(PT.textMuted)
            Text("No active sessions")
                .font(.headline)
                .foregroundStyle(PT.textSecondary)
            Text("Start a Pi session and it will appear here")
                .font(.subheadline)
                .foregroundStyle(PT.textMuted)
                .multilineTextAlignment(.center)

            if store.socket.connectionState != .connected {
                if let profile = store.activeProfile {
                    Button {
                        store.connectToProfile(profile)
                    } label: {
                        Label("Connect to \(profile.displayName)", systemImage: "bolt.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PT.accent)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .modifier(GlassCapsuleModifier(tint: PT.accent.opacity(0.12)))
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 32)
    }

    private var bannerText: String {
        switch store.socket.connectionState {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .failed(let r): return "Failed: \(r)"
        }
    }

    private var bannerColor: Color {
        switch store.socket.connectionState {
        case .connected: return PT.green
        case .connecting, .reconnecting: return PT.orange
        case .failed, .idle: return PT.red
        }
    }
}

// MARK: - Session Group Card

private struct SessionGroupCard: View {
    let groupKey: String
    let sessions: [RemoteSession]
    let onSelect: (RemoteSession) -> Void
    @State private var isExpanded = true

    private var groupActivity: String {
        if sessions.contains(where: { $0.activity == "speaking" }) { return "speaking" }
        let precedence = ["starting", "thinking", "reading", "editing", "running", "searching", "error"]
        if let work = precedence.first(where: { status in sessions.contains(where: { $0.activity == status }) }) {
            return work
        }
        if sessions.contains(where: { $0.activity == "queued" }) { return "queued" }
        return "waiting"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if groupActivity == "speaking" {
                        PulsingDot(color: PT.red)
                    } else {
                        Circle().fill(activityColor(groupActivity)).frame(width: 8, height: 8)
                    }
                    Text(shortGroupKey(groupKey))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PT.textPrimary)
                        .lineLimit(1)
                    StatusChip(label: "\(sessions.count)", color: PT.textMuted)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PT.textMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if isExpanded {
                let sorted = sessions.sorted { ($0.pid ?? 0) < ($1.pid ?? 0) }
                VStack(spacing: 2) {
                    ForEach(sorted) { session in
                        SessionRow(session: session, onSelect: { onSelect(session) })
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
        raw.contains("/") ? (raw.components(separatedBy: "/").last ?? raw) : raw
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: RemoteSession
    let onSelect: () -> Void

    private var label: String {
        if let p = session.project, !p.isEmpty { return p }
        if let m = session.mux, !m.isEmpty { return m }
        return session.sourceApp
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                if session.activity == "speaking" {
                    PulsingDot(color: activityColor(session.activity))
                } else {
                    Circle().fill(activityColor(session.activity)).frame(width: 7, height: 7)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(PT.textPrimary)
                            .lineLimit(1)
                        if let pid = session.pid {
                            Text("pid \(pid)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(PT.textMuted)
                        }
                    }
                    if let detail = session.statusDetail, !detail.isEmpty, isWorkActivity(session.activity) {
                        Text(detail).font(.caption).foregroundStyle(PT.textSecondary).lineLimit(1)
                    } else if let text = session.currentText ?? session.lastSpokenText {
                        Text(text).font(.caption).foregroundStyle(PT.textSecondary).lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                if session.queuedCount > 0 {
                    StatusChip(label: "\(session.queuedCount)q", color: PT.orange)
                }
                StatusChip(label: session.activityLabel, color: activityColor(session.activity))

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(PT.textMuted.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .modifier(GlassRectModifier(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session Full Screen

private struct SessionFullScreen: View {
    @EnvironmentObject private var store: AppStore
    let sessionId: String
    let onBack: () -> Void
    let onSettings: () -> Void

    private var session: RemoteSession? {
        store.socket.snapshot.sessions.first(where: { $0.id == sessionId })
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader.padding(.bottom, 2)
            SessionDetailView(sessionId: sessionId).environmentObject(store)
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Sessions")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(PT.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .modifier(GlassCapsuleModifier())
            }

            Spacer()

            if let session {
                HStack(spacing: 6) {
                    if session.activity == "speaking" {
                        PulsingDot(color: PT.red)
                    } else if isWorkActivity(session.activity) {
                        Circle().fill(activityColor(session.activity)).frame(width: 8, height: 8)
                    }
                    Text(session.project ?? session.sourceApp)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PT.textPrimary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let session, session.activity == "speaking" || isWorkActivity(session.activity) {
                Button { store.stopAll() } label: {
                    Image(systemName: "stop.fill")
                        .font(.caption2)
                        .foregroundStyle(PT.red)
                        .frame(width: 32, height: 32)
                        .modifier(GlassCircleModifier())
                }
            } else {
                Button(action: onSettings) {
                    Image(systemName: "gear")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PT.textSecondary)
                        .frame(width: 32, height: 32)
                        .modifier(GlassCircleModifier())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
