import Foundation
import SwiftUI
import Combine

// MARK: - Voice Session Model

enum VoiceActivity: Equatable {
    case speaking
    case queued
    case starting
    case thinking
    case reading
    case editing
    case running
    case searching
    case error
    case waiting
    case idle

    var label: String {
        switch self {
        case .speaking: return "Speaking"
        case .queued: return "Queued"
        case .starting: return "Starting"
        case .thinking: return "Thinking"
        case .reading: return "Reading"
        case .editing: return "Editing"
        case .running: return "Running"
        case .searching: return "Searching"
        case .error: return "Error"
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .speaking: return .red
        case .queued: return .orange
        case .starting: return .green
        case .thinking: return .orange
        case .reading: return .blue
        case .editing: return .yellow
        case .running: return .orange
        case .searching: return Color(red: 0.78, green: 0.33, blue: 0.08)  // burnt orange
        case .error: return .red
        case .waiting: return .green
        case .idle: return .secondary
        }
    }

    var isWorkStatus: Bool {
        switch self {
        case .starting, .thinking, .reading, .editing, .running, .searching, .error:
            return true
        default:
            return false
        }
    }
}

struct VoiceSession: Identifiable, Equatable {
    let id: String
    let sourceApp: String
    let sessionId: String?
    let pid: Int?

    var activity: VoiceActivity
    var statusDetail: String?   // e.g. "reading App.swift", "running ls"
    var project: String?        // project/directory name from extension
    var currentText: String?
    var queuedCount: Int
    var voice: String?
    var lastSpokenAt: Date?
    var lastSpokenText: String?
    var cwd: String?
    var tty: String?
    var mux: String?
}

struct VoiceSummary: Equatable {
    let total: Int
    let speaking: Int
    let queued: Int
    let idle: Int
    let color: String
    let label: String

    var uiColor: Color {
        switch color {
        case "red": return .red
        case "yellow": return .yellow
        case "green": return .green
        case "orange": return .orange
        case "blue": return .blue
        case "purple": return .purple
        default: return .gray
        }
    }

    static let empty = VoiceSummary(
        total: 0, speaking: 0, queued: 0, idle: 0,
        color: "gray", label: "No voice activity"
    )
}

// MARK: - Voice Monitor (push-based)

@MainActor
final class VoiceMonitor: ObservableObject {
    @Published private(set) var sessions: [VoiceSession] = []
    @Published private(set) var summary: VoiceSummary = .empty
    @Published private(set) var serverOnline: Bool = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var recentHistory: [RequestHistoryEntry] = []

    private var cancellables = Set<AnyCancellable>()
    private var statusObserver: NSObjectProtocol?
    private var micObserver: NSObjectProtocol?
    private var isStarted = false
    private let historyStore = RequestHistoryStore.shared
    private let activeSessionWindow: TimeInterval = 5 * 60

    var speakingCount: Int { sessions.filter { $0.activity == .speaking }.count }
    var queuedCount: Int { sessions.filter { $0.activity == .queued }.count }
    var totalQueuedItems: Int { recentHistory.filter { $0.status == .queued }.count }

    var isMicActive: Bool = false

    @Published var serverEnabled: Bool = !UserDefaults.standard.bool(forKey: "serverDisabled")

    @Published var speechSpeed: Double = min(2.0, max(0.7, UserDefaults.standard.object(forKey: "speechSpeed") as? Double ?? 1.0)) {
        didSet {
            let clamped = min(2.0, max(0.7, speechSpeed))
            if clamped != speechSpeed { speechSpeed = clamped }
            else { UserDefaults.standard.set(speechSpeed, forKey: "speechSpeed") }
        }
    }

    func handleServerToggle(enabled: Bool) {
        UserDefaults.standard.set(!enabled, forKey: "serverDisabled")
        guard let appDelegate = AppDelegate.shared else { return }
        if enabled {
            appDelegate.speechCoordinator?.isMuted = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                appDelegate.startLocalBroker()
            }
        } else {
            appDelegate.speechCoordinator?.stopAll()
            appDelegate.speechCoordinator?.isMuted = true
            appDelegate.stopLocalBroker()
        }
    }

    init() {
        // React to mic activity changes
        micObserver = NotificationCenter.default.addObserver(
            forName: .micActivityChanged, object: nil, queue: .main
        ) { [weak self] notification in
            if let isActive = notification.userInfo?["isActive"] as? Bool {
                Task { @MainActor in self?.isMicActive = isActive }
            }
        }

        // Start listening immediately
        start()
    }

    deinit {
        if let observer = micObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = statusObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Subscribe to agent status events (from pi extension via broker)
        if statusObserver == nil {
            statusObserver = NotificationCenter.default.addObserver(
                forName: .agentStatusChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.rebuild() }
            }
        }

        // Subscribe to history changes (speech queue state)
        historyStore.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        // Initial build
        rebuild()
    }

    func stop() {
        isStarted = false
        cancellables.removeAll()
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
            statusObserver = nil
        }
    }

    // MARK: - Rebuild (replaces the old polling refresh)

    private func rebuild() {
        let entries = historyStore.entries
        let agents = AgentStatusStore.shared.allAgents()
        let isMicActive = self.isMicActive
        let currentSessions = self.sessions

        let agentInstances = agents.map { agent in
            AgentInstance(
                pid: agent.pid,
                cwd: agent.cwd,
                activity: Self.mapStatus(agent.status),
                detail: agent.detail,
                project: agent.project
            )
        }

        let inboxPids = Self.activeInboxPids()

        let newSessions = Self.buildSessions(
            from: entries,
            agents: agentInstances,
            inboxPids: inboxPids,
            activeSessionWindow: activeSessionWindow
        )

        // Freeze UI order while mic is active
        if isMicActive && !currentSessions.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: newSessions.map { ($0.id, $0) })
            var ordered = currentSessions.compactMap { byId[$0.id] }
            for s in newSessions where !ordered.contains(where: { $0.id == s.id }) {
                ordered.append(s)
            }
            sessions = ordered
        } else {
            sessions = newSessions
        }

        summary = Self.buildSummary(from: sessions)
        recentHistory = Array(entries.filter { !$0.status.isInQueue }
            .sorted { $0.timestamp > $1.timestamp }.prefix(10))
        checkServerHealth()
    }

    // MARK: - Agent Instance

    private struct AgentInstance {
        let pid: Int
        let cwd: String?
        let activity: VoiceActivity
        let detail: String?
        let project: String?
    }

    private static func mapStatus(_ status: String) -> VoiceActivity {
        switch status {
        case "starting": return .starting
        case "thinking": return .thinking
        case "reading": return .reading
        case "editing": return .editing
        case "running": return .running
        case "searching": return .searching
        case "error": return .error
        case "done": return .waiting
        default: return .idle
        }
    }

    // MARK: - Actions

    func stopAll() {
        AppDelegate.shared?.stopCurrentSpeech()
        RequestHistoryStore.shared.cancelAllPending()
        lastMessage = "Stopped all speech"
    }

    func jump(to session: VoiceSession) {
        guard let pid = session.pid else {
            lastMessage = "No PID available for jump"
            return
        }
        lastMessage = "Jumping to PID \(pid)..."
        JumpHandler.jumpAsync(to: pid) { [weak self] result in
            self?.lastMessage = result.focused
                ? "Focused \(result.focusedApp ?? "terminal") for PID \(pid)"
                : (result.message ?? "Could not focus terminal")
        }
    }

    func sendText(to session: VoiceSession, text: String) {
        guard let pid = session.pid else {
            lastMessage = "No PID available"
            return
        }
        lastMessage = "Sending..."
        SendHandler.send(pid: pid, tty: nil, mux: nil, text: text) { [weak self] result in
            self?.lastMessage = result.message ?? (result.success ? "Sent" : "Failed")
        }
    }

    // MARK: - Build Sessions

    private static func buildSessions(
        from entries: [RequestHistoryEntry],
        agents: [AgentInstance],
        inboxPids: [Int],
        activeSessionWindow: TimeInterval
    ) -> [VoiceSession] {
        var sessions: [VoiceSession] = []
        var seenPids = Set<Int>()

        // Sessions from live agent status events
        for agent in agents {
            seenPids.insert(agent.pid)
            let cwdName = agent.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }

            var session = VoiceSession(
                id: "pid-\(agent.pid)",
                sourceApp: "pi",
                sessionId: cwdName,
                pid: agent.pid,
                activity: agent.activity,
                statusDetail: agent.detail,
                project: agent.project ?? cwdName,
                currentText: nil,
                queuedCount: 0,
                voice: nil,
                lastSpokenAt: nil,
                lastSpokenText: nil,
                cwd: agent.cwd,
                tty: nil,
                mux: nil
            )

            // Overlay voice history
            let pidEntries = entries.filter { $0.pid == agent.pid }
            if !pidEntries.isEmpty {
                let recentCutoff = Date().addingTimeInterval(-120)
                let playingEntry = pidEntries.first { $0.status == .playing && $0.timestamp > recentCutoff }
                let queuedEntries = pidEntries.filter { $0.status == .queued && $0.timestamp > recentCutoff }
                let playedEntries = pidEntries.filter { $0.status == .played }

                // Keep live agent status as the primary activity signal.
                // Only fall back to speech-based activity when agent reports idle/waiting.
                if let playing = playingEntry {
                    if session.activity == .idle || session.activity == .waiting {
                        session.activity = .speaking
                    }
                    session.currentText = playing.text
                    session.queuedCount = queuedEntries.count
                } else if !queuedEntries.isEmpty {
                    if session.activity == .idle || session.activity == .waiting {
                        session.activity = .queued
                    }
                    session.currentText = queuedEntries.first?.text
                    session.queuedCount = queuedEntries.count
                }

                if let lastPlayed = playedEntries.max(by: { $0.timestamp < $1.timestamp }) {
                    session.lastSpokenAt = lastPlayed.timestamp
                    session.lastSpokenText = lastPlayed.text
                }
                session.voice = pidEntries.compactMap { $0.voice }.first
            }

            sessions.append(session)
        }

        // Also show sessions with recent speech activity (even without live status events)
        let recentCutoff = Date().addingTimeInterval(-activeSessionWindow)
        var voiceBuckets: [Int: [RequestHistoryEntry]] = [:]  // keyed by pid
        for entry in entries {
            guard let pid = entry.pid, !seenPids.contains(pid) else { continue }
            guard entry.timestamp > recentCutoff else { continue }
            voiceBuckets[pid, default: []].append(entry)
        }

        for (pid, pidEntries) in voiceBuckets {
            let key = "pid-\(pid)"
            guard !sessions.contains(where: { $0.id == key }) else { continue }

            let playingEntry = pidEntries.first { $0.status == .playing }
            let queuedEntries = pidEntries.filter { $0.status == .queued }
            let playedEntries = pidEntries.filter { $0.status == .played }

            var activity: VoiceActivity = .idle
            var currentText: String? = nil

            if playingEntry != nil {
                activity = .speaking
                currentText = playingEntry?.text
            } else if !queuedEntries.isEmpty {
                activity = .queued
                currentText = queuedEntries.first?.text
            } else {
                // Don't keep idle fallback-only sessions around for long.
                let lastEventAt = pidEntries.max(by: { $0.timestamp < $1.timestamp })?.timestamp ?? .distantPast
                if Date().timeIntervalSince(lastEventAt) > 45 {
                    continue
                }
            }

            // Get project name from process cwd
            let projectName = Self.cwdForPid(pid).map { URL(fileURLWithPath: $0).lastPathComponent }

            sessions.append(VoiceSession(
                id: key,
                sourceApp: normalizedAppName(pidEntries.first?.sourceApp),
                sessionId: pidEntries.first?.sessionId,
                pid: pid,
                activity: activity,
                statusDetail: nil,
                project: projectName,
                currentText: currentText,
                queuedCount: queuedEntries.count,
                voice: pidEntries.compactMap { $0.voice }.first,
                lastSpokenAt: playedEntries.max(by: { $0.timestamp < $1.timestamp })?.timestamp,
                lastSpokenText: playedEntries.max(by: { $0.timestamp < $1.timestamp })?.text,
                cwd: Self.cwdForPid(pid),
                tty: nil,
                mux: nil
            ))
            seenPids.insert(pid)
        }

        // Final fallback: extension-owned inbox pids that are active but haven't emitted status/speech yet.
        for pid in inboxPids where !seenPids.contains(pid) {
            let cwd = Self.cwdForPid(pid)
            let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            sessions.append(VoiceSession(
                id: "pid-\(pid)",
                sourceApp: "pi",
                sessionId: nil,
                pid: pid,
                activity: .waiting,
                statusDetail: nil,
                project: project,
                currentText: nil,
                queuedCount: 0,
                voice: nil,
                lastSpokenAt: nil,
                lastSpokenText: nil,
                cwd: cwd,
                tty: nil,
                mux: nil
            ))
            seenPids.insert(pid)
        }

        // Sort: speaking > active work states > queued > waiting > idle, then by recency
        let order: [VoiceActivity] = [.speaking, .starting, .thinking, .reading, .editing, .running, .searching, .error, .queued, .waiting, .idle]
        return sessions.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs.activity) ?? 99
            let ri = order.firstIndex(of: rhs.activity) ?? 99
            if li != ri { return li < ri }
            let lt = lhs.lastSpokenAt ?? .distantPast
            let rt = rhs.lastSpokenAt ?? .distantPast
            if lt != rt { return lt > rt }
            return (lhs.pid ?? 0) < (rhs.pid ?? 0)
        }
    }

    private static func buildSummary(from sessions: [VoiceSession]) -> VoiceSummary {
        let total = sessions.count
        let speaking = sessions.filter { $0.activity == .speaking }.count
        let workingSessions = sessions.filter { $0.activity.isWorkStatus }
        let working = workingSessions.count
        let queued = sessions.filter { $0.activity == .queued }.count
        let waiting = sessions.filter { $0.activity == .waiting }.count
        let idle = total - speaking - working - queued - waiting

        let color: String
        let label: String

        if total == 0 {
            color = "default"
            label = "No Pi agents"
        } else if speaking > 0 {
            color = "red"
            label = speaking == 1 ? "Speaking" : "\(speaking) speaking"
        } else if working > 0 {
            let precedence: [VoiceActivity] = [.starting, .thinking, .reading, .editing, .running, .searching, .error]
            let primary = precedence.first { activity in sessions.contains(where: { $0.activity == activity }) } ?? .running
            let primaryCount = sessions.filter { $0.activity == primary }.count
            switch primary {
            case .starting: color = "green"
            case .thinking: color = "orange"
            case .reading: color = "blue"
            case .editing: color = "yellow"
            case .running: color = "orange"
            case .searching: color = "orange"
            case .error: color = "red"
            default: color = "default"
            }
            label = working == 1
                ? primary.label
                : (primaryCount == working ? "\(primaryCount) \(primary.label.lowercased())" : "\(working) active")
        } else if queued > 0 {
            color = "orange"
            label = queued == 1 ? "Queued" : "\(queued) queued"
        } else if waiting > 0 {
            color = "green"
            label = waiting == 1 ? "Waiting" : "\(waiting) waiting"
        } else {
            color = "default"
            label = "Idle"
        }

        return VoiceSummary(total: total, speaking: speaking, queued: queued, idle: idle, color: color, label: label)
    }

    private func checkServerHealth() {
        switch SpeechPlaybackCoordinator.currentProvider {
        case .elevenlabs:
            serverOnline = ElevenLabsApiKeyManager.resolvedKey() != nil
        case .google:
            serverOnline = GoogleApiKeyManager.resolvedKey() != nil
        case .deepgram:
            serverOnline = DeepgramApiKeyManager.resolvedKey() != nil
        case .local:
            serverOnline = LocalTTSRuntime.shared.isRuntimeAvailable() && LocalTTSRuntime.shared.isModelInstalled()
        }
    }

    /// Discover active pi sessions from extension-owned inbox directories.
    /// This avoids telemetry polling and gives us a stable fallback session list.
    private static func activeInboxPids() -> [Int] {
        let inboxRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/pitalk-inbox", isDirectory: true)

        guard let items = try? FileManager.default.contentsOfDirectory(
            at: inboxRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let now = Date()
        let maxAge: TimeInterval = 60 * 60 * 6  // ignore very stale crash leftovers

        return items.compactMap { url in
            guard let pid = Int(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate,
               now.timeIntervalSince(modified) > maxAge {
                return nil
            }
            return pid
        }
    }

    private static let cwdCacheLock = NSLock()
    private static var cwdCache: [Int: (path: String, updatedAt: Date)] = [:]
    private static let cwdCacheTTL: TimeInterval = 10

    /// Best-effort cwd lookup for pid (used when extension status events are unavailable).
    private static func cwdForPid(_ pid: Int) -> String? {
        let now = Date()
        cwdCacheLock.lock()
        if let cached = cwdCache[pid], now.timeIntervalSince(cached.updatedAt) < cwdCacheTTL {
            cwdCacheLock.unlock()
            return cached.path
        }
        cwdCacheLock.unlock()

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            for line in output.split(separator: "\n") where line.hasPrefix("n/") {
                let path = String(line.dropFirst())
                cwdCacheLock.lock()
                cwdCache[pid] = (path: path, updatedAt: now)
                cwdCacheLock.unlock()
                return path
            }
        } catch {}

        cwdCacheLock.lock()
        cwdCache.removeValue(forKey: pid)
        cwdCacheLock.unlock()
        return nil
    }

    private static func normalizedAppName(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "Unknown"
    }

}
