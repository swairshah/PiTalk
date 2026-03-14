import Foundation

/// Notification posted when agent status changes.
/// Observers should refresh their session state.
extension Notification.Name {
    static let agentStatusChanged = Notification.Name("agentStatusChanged")
}

/// Stores real-time agent status events received from the pi-talk extension via the broker.
/// Posts a notification on every update so VoiceMonitor can react instantly (no polling).
final class AgentStatusStore {
    static let shared = AgentStatusStore()

    struct AgentStatus {
        let pid: Int
        let project: String?
        let cwd: String?
        let status: String       // "starting", "thinking", "reading", "editing", "running", "searching", "done", "error"
        let detail: String?
        let contextPercent: Int?
        let updatedAt: Date
    }

    private let lock = NSLock()
    private var agents: [Int: AgentStatus] = [:]  // keyed by pid
    private let staleInterval: TimeInterval = 5 * 60  // 5 minutes — agents waiting for input don't send events

    private init() {}

    func update(pid: Int, project: String?, cwd: String?, status: String, detail: String?, contextPercent: Int?) {
        lock.lock()
        agents[pid] = AgentStatus(
            pid: pid, project: project, cwd: cwd,
            status: status, detail: detail,
            contextPercent: contextPercent, updatedAt: Date()
        )
        lock.unlock()
        NotificationCenter.default.post(name: .agentStatusChanged, object: nil)
    }

    func remove(pid: Int) {
        lock.lock()
        agents.removeValue(forKey: pid)
        lock.unlock()
        NotificationCenter.default.post(name: .agentStatusChanged, object: nil)
    }

    func allAgents() -> [AgentStatus] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let staleKeys = agents.filter { now.timeIntervalSince($0.value.updatedAt) > staleInterval }.map(\.key)
        for key in staleKeys { agents.removeValue(forKey: key) }
        return Array(agents.values)
    }
}
