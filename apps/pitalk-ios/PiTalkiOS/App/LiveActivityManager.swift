import ActivityKit
import Foundation

/// Manages Live Activities for active PiTalk sessions.
/// One Live Activity per session that is speaking or queued.
/// Sessions that go idle get their activity ended after a short grace period.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// Map session key → live activity
    private var activities: [String: Activity<PiTalkActivityAttributes>] = [:]
    /// Grace timers: when a session goes idle, wait before ending its activity.
    private var idleTimers: [String: Task<Void, Never>] = [:]

    private let idleGracePeriod: TimeInterval = 8

    private init() {}

    // MARK: - Public API

    /// Reconcile live activities with the current snapshot.
    /// Call this on every snapshot update.
    func reconcile(
        sessions: [RemoteSession],
        serverName: String
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let sessionsByKey = Dictionary(grouping: sessions, by: { $0.id })

        // Update or start activities for active sessions.
        for session in sessions {
            let key = session.id
            let isActive = session.activity == "speaking" || isWorkActivity(session.activity) || session.activity == "queued"

            if isActive {
                // Cancel any pending idle timer.
                idleTimers[key]?.cancel()
                idleTimers.removeValue(forKey: key)

                if activities[key] != nil {
                    updateActivity(for: session)
                } else {
                    startActivity(for: session, serverName: serverName)
                }
            } else {
                // Session is idle/waiting — schedule end if activity exists.
                if activities[key] != nil, idleTimers[key] == nil {
                    scheduleEnd(for: session)
                }
            }
        }

        // End activities for sessions that no longer exist.
        let currentKeys = Set(sessions.map(\.id))
        for key in activities.keys where !currentKeys.contains(key) {
            endActivity(forKey: key, summary: nil)
        }
    }

    /// End all live activities (e.g. on disconnect).
    func endAll() {
        for key in activities.keys {
            endActivity(forKey: key, summary: nil)
        }
        for timer in idleTimers.values {
            timer.cancel()
        }
        idleTimers.removeAll()
    }

    // MARK: - Private

    private func startActivity(for session: RemoteSession, serverName: String) {
        let projectName = shortName(session.project ?? session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? session.sourceApp)
        let agentName = session.project ?? session.sourceApp

        let attributes = PiTalkActivityAttributes(
            sessionKey: session.id,
            agentName: agentName,
            projectName: projectName,
            serverName: serverName
        )
        let state = contentState(from: session)
        let content = ActivityContent(state: state, staleDate: nil)

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            activities[session.id] = activity
        } catch {
            // Live Activities may be disabled or at capacity.
        }
    }

    private func updateActivity(for session: RemoteSession) {
        guard let activity = activities[session.id] else { return }
        let state = contentState(from: session)
        let content = ActivityContent(state: state, staleDate: nil)
        Task { await activity.update(content) }
    }

    private func scheduleEnd(for session: RemoteSession) {
        let key = session.id
        let lastText = session.lastSpokenText

        idleTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.idleGracePeriod ?? 8))
            guard !Task.isCancelled else { return }
            await self?.endActivity(forKey: key, summary: lastText)
        }
    }

    private func endActivity(forKey key: String, summary: String?) {
        guard let activity = activities.removeValue(forKey: key) else { return }
        idleTimers[key]?.cancel()
        idleTimers.removeValue(forKey: key)

        let finalState = PiTalkActivityAttributes.ContentState(
            activity: "waiting",
            activityLabel: "Done",
            currentText: nil,
            lastSpokenText: summary,
            queuedCount: 0,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            isFinished: true
        )
        let content = ActivityContent(state: finalState, staleDate: nil)
        Task {
            await activity.end(content, dismissalPolicy: .after(.now + 6))
        }
    }

    private func contentState(from session: RemoteSession) -> PiTalkActivityAttributes.ContentState {
        PiTalkActivityAttributes.ContentState(
            activity: session.activity,
            activityLabel: session.activityLabel,
            currentText: session.currentText,
            lastSpokenText: session.lastSpokenText,
            queuedCount: session.queuedCount,
            updatedAtMs: session.lastSpokenAtMs ?? Int64(Date().timeIntervalSince1970 * 1000),
            isFinished: false
        )
    }

    private func shortName(_ raw: String) -> String {
        if raw.contains("/") {
            return raw.components(separatedBy: "/").last ?? raw
        }
        return raw
    }
}
