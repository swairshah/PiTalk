import Foundation
import SwiftUI

// Debug logging - only prints when PITALK_DEBUG=1
fileprivate let debugEnabled = ProcessInfo.processInfo.environment["PITALK_DEBUG"] == "1"
fileprivate func debugLog(_ message: String) {
    if debugEnabled {
        print(message)
    }
}

// MARK: - Voice Session Model

enum VoiceActivity: Equatable {
    case speaking
    case queued  
    case running   // Pi is actively working
    case waiting   // Pi is waiting for input
    case idle
    
    var label: String {
        switch self {
        case .speaking: return "Speaking"
        case .queued: return "Queued"
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .idle: return "Idle"
        }
    }
    
    var color: Color {
        switch self {
        case .speaking: return .red
        case .queued: return .orange
        case .running: return .red
        case .waiting: return .green
        case .idle: return .secondary
        }
    }
}

struct VoiceSession: Identifiable, Equatable {
    let id: String  // sourceApp::sessionId or pid-based
    let sourceApp: String
    let sessionId: String?
    let pid: Int?
    
    var activity: VoiceActivity
    var currentText: String?
    var queuedCount: Int
    var voice: String?
    var lastSpokenAt: Date?
    var lastSpokenText: String?
    var cwd: String?
    var tty: String?
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
        default: return .gray
        }
    }
    
    static let empty = VoiceSummary(
        total: 0,
        speaking: 0,
        queued: 0,
        idle: 0,
        color: "gray",
        label: "No voice activity"
    )
}

// MARK: - Voice Monitor

@MainActor
final class VoiceMonitor: ObservableObject {
    @Published private(set) var sessions: [VoiceSession] = []
    @Published private(set) var summary: VoiceSummary = .empty
    @Published private(set) var serverOnline: Bool = false
    @Published private(set) var lastMessage: String?
    @Published private(set) var recentHistory: [RequestHistoryEntry] = []
    
    private var timer: Timer?
    private let historyStore = RequestHistoryStore.shared
    private let activeSessionWindow: TimeInterval = 5 * 60  // 5 minutes
    
    var speakingCount: Int { sessions.filter { $0.activity == .speaking }.count }
    var queuedCount: Int { sessions.filter { $0.activity == .queued }.count }
    var totalQueuedItems: Int { recentHistory.filter { $0.status == .queued }.count }
    
    init() {
        // Start monitoring immediately so the menubar icon shows correct state on launch
        start()
    }
    
    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    
    func refresh() {
        // Read pi telemetry for accurate status
        let telemetryInstances = readPiTelemetry()
        
        // Build sessions from history entries + telemetry
        let entries = historyStore.entries
        sessions = buildSessions(from: entries, telemetry: telemetryInstances)
        summary = buildSummary(from: sessions)
        
        // Get recent history (last 10 completed items)
        recentHistory = Array(entries
            .filter { !$0.status.isInQueue }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(10))
        
        // Check server status
        checkServerHealth()
    }
    
    // MARK: - Telemetry Reading
    
    struct PiTelemetryInstance {
        let pid: Int
        let cwd: String?
        let activity: VoiceActivity
        let sessionId: String?
        let modelName: String?
        let contextPercent: Double?
    }
    
    private func readPiTelemetry() -> [PiTelemetryInstance] {
        let telemetryDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/telemetry/instances")
        
        guard FileManager.default.fileExists(atPath: telemetryDir.path) else {
            return []
        }
        
        let staleMs: Int64 = 10000  // 10 seconds
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        
        var instances: [PiTelemetryInstance] = []
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: telemetryDir, includingPropertiesForKeys: nil)
            
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                
                // Get process info
                guard let process = json["process"] as? [String: Any],
                      let pid = process["pid"] as? Int,
                      let updatedAt = process["updatedAt"] as? Int64 else {
                    continue
                }
                
                // Check if process is still alive
                if kill(Int32(pid), 0) != 0 {
                    continue
                }
                
                // Check if telemetry is stale
                if nowMs - updatedAt > staleMs {
                    continue
                }
                
                // Get workspace/cwd
                let workspace = json["workspace"] as? [String: Any]
                let cwd = workspace?["cwd"] as? String
                
                // Get session info
                let session = json["session"] as? [String: Any]
                let sessionId = session?["id"] as? String
                
                // Get model info
                let model = json["model"] as? [String: Any]
                let modelName = model?["name"] as? String
                
                // Get state/activity
                let state = json["state"] as? [String: Any]
                let activity = mapTelemetryActivity(state)
                
                // Get context info
                let context = json["context"] as? [String: Any]
                let contextPercent = context?["percent"] as? Double
                
                instances.append(PiTelemetryInstance(
                    pid: pid,
                    cwd: cwd,
                    activity: activity,
                    sessionId: sessionId,
                    modelName: modelName,
                    contextPercent: contextPercent
                ))
            }
        } catch {
            debugLog("PiTalk: Error reading telemetry: \(error)")
        }
        
        return instances
    }
    
    private func mapTelemetryActivity(_ state: [String: Any]?) -> VoiceActivity {
        guard let state = state else { return .idle }
        
        // Check activity field first
        if let activity = state["activity"] as? String {
            switch activity {
            case "working":
                return .running
            case "waiting_input":
                return .waiting
            default:
                break
            }
        }
        
        // Fallback to boolean fields
        if state["waitingForInput"] as? Bool == true {
            return .waiting
        }
        if state["busy"] as? Bool == true || state["isIdle"] as? Bool == false {
            return .running
        }
        if state["isIdle"] as? Bool == true {
            return .idle
        }
        
        return .idle
    }
    
    func stopAll() {
        // Get app delegate and call stopCurrentSpeech
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.stopCurrentSpeech()
        }
        lastMessage = "Stopped all speech"
    }
    
    func jump(to session: VoiceSession) {
        guard let pid = session.pid else {
            lastMessage = "No PID available for jump"
            debugLog("PiTalk: Jump failed - no PID")
            return
        }
        
        debugLog("PiTalk: Jump requested for PID \(pid)")
        lastMessage = "Jumping to PID \(pid)..."
        
        // Use native Swift JumpHandler (no daemon needed)
        JumpHandler.jumpAsync(to: pid) { [weak self] result in
            debugLog("PiTalk: JumpHandler result: focused=\(result.focused), app=\(result.focusedApp ?? "nil"), msg=\(result.message ?? "nil")")
            if result.focused {
                self?.lastMessage = "Focused \(result.focusedApp ?? "terminal") for PID \(pid)"
            } else {
                self?.lastMessage = result.message ?? "Could not focus terminal"
            }
        }
    }
    
    private func buildSessions(from entries: [RequestHistoryEntry], telemetry: [PiTelemetryInstance]) -> [VoiceSession] {
        var sessions: [VoiceSession] = []
        var seenPids = Set<Int>()
        
        // First, create sessions from pi telemetry (accurate status)
        for instance in telemetry {
            seenPids.insert(instance.pid)
            
            let cwdName = instance.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            
            var session = VoiceSession(
                id: "pid-\(instance.pid)",
                sourceApp: "pi",
                sessionId: cwdName,
                pid: instance.pid,
                activity: instance.activity,
                currentText: nil,
                queuedCount: 0,
                voice: nil,
                lastSpokenAt: nil,
                lastSpokenText: nil,
                cwd: instance.cwd,
                tty: nil
            )
            
            // Check if this pid has any voice history
            let pidEntries = entries.filter { $0.pid == instance.pid }
            if !pidEntries.isEmpty {
                let playingEntry = pidEntries.first { $0.status == .playing }
                let queuedEntries = pidEntries.filter { $0.status == .queued }
                let playedEntries = pidEntries.filter { $0.status == .played }
                
                if let playing = playingEntry {
                    session.activity = .speaking
                    session.currentText = playing.text
                    session.queuedCount = queuedEntries.count
                } else if !queuedEntries.isEmpty {
                    session.activity = .queued
                    session.currentText = queuedEntries.first?.text
                    session.queuedCount = queuedEntries.count
                }
                
                if let lastPlayed = playedEntries.sorted(by: { $0.timestamp > $1.timestamp }).first {
                    session.lastSpokenAt = lastPlayed.timestamp
                    session.lastSpokenText = lastPlayed.text
                }
                
                session.voice = pidEntries.compactMap { $0.voice }.first
            }
            
            sessions.append(session)
        }
        
        // Also add any voice sessions that don't have a current pi process
        // (e.g., from recent history where the process has since exited)
        let cutoff = Date().addingTimeInterval(-activeSessionWindow)
        var voiceOnlyBuckets: [String: [RequestHistoryEntry]] = [:]
        
        for entry in entries {
            // Skip if we already have this pid from process scan
            if let pid = entry.pid, seenPids.contains(pid) { continue }
            
            let sourceApp = normalizedAppName(entry.sourceApp)
            let sessionId = normalizedSessionId(entry.sessionId)
            let key = "\(sourceApp)::\(sessionId ?? "__none__")"
            
            voiceOnlyBuckets[key, default: []].append(entry)
        }
        
        for (key, bucketEntries) in voiceOnlyBuckets {
            let sorted = bucketEntries.sorted { $0.timestamp > $1.timestamp }
            guard let mostRecent = sorted.first, mostRecent.timestamp >= cutoff else { continue }
            
            let parts = key.split(separator: ":", maxSplits: 2)
            let sourceApp = parts.count > 0 ? String(parts[0]) : "unknown"
            let sessionId = parts.count > 1 ? String(parts[1].dropFirst()) : nil // drop leading ":"
            
            let playingEntry = bucketEntries.first { $0.status == .playing }
            let queuedEntries = bucketEntries.filter { $0.status == .queued }
            let playedEntries = bucketEntries.filter { $0.status == .played }
            
            var activity: VoiceActivity = .idle
            var currentText: String? = nil
            var queuedCount = 0
            
            if let playing = playingEntry {
                activity = .speaking
                currentText = playing.text
                queuedCount = queuedEntries.count
            } else if !queuedEntries.isEmpty {
                activity = .queued
                currentText = queuedEntries.first?.text
                queuedCount = queuedEntries.count
            }
            
            let session = VoiceSession(
                id: key,
                sourceApp: sourceApp,
                sessionId: sessionId == "__none__" ? nil : sessionId,
                pid: bucketEntries.compactMap { $0.pid }.first,
                activity: activity,
                currentText: currentText,
                queuedCount: queuedCount,
                voice: mostRecent.voice,
                lastSpokenAt: playedEntries.sorted(by: { $0.timestamp > $1.timestamp }).first?.timestamp,
                lastSpokenText: playedEntries.sorted(by: { $0.timestamp > $1.timestamp }).first?.text,
                cwd: nil,
                tty: nil
            )
            
            sessions.append(session)
        }
        
        // Sort: speaking first, then running, then queued, then waiting, then idle
        // Within each group, sort by most recent audio activity (lastSpokenAt)
        return sessions.sorted { lhs, rhs in
            let order: [VoiceActivity] = [.speaking, .running, .queued, .waiting, .idle]
            let lhsIdx = order.firstIndex(of: lhs.activity) ?? 99
            let rhsIdx = order.firstIndex(of: rhs.activity) ?? 99
            if lhsIdx != rhsIdx {
                return lhsIdx < rhsIdx
            }
            // Within same activity, sort by most recent audio (most recent first)
            let lhsTime = lhs.lastSpokenAt ?? .distantPast
            let rhsTime = rhs.lastSpokenAt ?? .distantPast
            if lhsTime != rhsTime {
                return lhsTime > rhsTime
            }
            // Finally by PID as tiebreaker
            return (lhs.pid ?? 0) < (rhs.pid ?? 0)
        }
    }
    
    private func buildSummary(from sessions: [VoiceSession]) -> VoiceSummary {
        let total = sessions.count
        let speaking = sessions.filter { $0.activity == .speaking }.count
        let running = sessions.filter { $0.activity == .running }.count
        let queued = sessions.filter { $0.activity == .queued }.count
        let waiting = sessions.filter { $0.activity == .waiting }.count
        let idle = total - speaking - running - queued - waiting
        
        let color: String
        let label: String
        
        // Simple color logic: green if ANY session is waiting for input, otherwise default
        if waiting > 0 {
            color = "green"
            label = "\(waiting) waiting for input"
        } else if total == 0 {
            color = "default"
            label = "No Pi agents"
        } else if speaking > 0 {
            color = "default"
            label = "Speaking"
        } else if running > 0 {
            color = "default"
            label = "\(running) running"
        } else if queued > 0 {
            color = "default"
            label = "Queued"
        } else {
            color = "default"
            label = "Idle"
        }
        
        return VoiceSummary(
            total: total,
            speaking: speaking,
            queued: queued,
            idle: idle,
            color: color,
            label: label
        )
    }
    
    private func checkServerHealth() {
        // Check if ElevenLabs API key is configured
        let hasApiKey = ProcessInfo.processInfo.environment["ELEVEN_API_KEY"] != nil 
            || ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] != nil
            || (UserDefaults.standard.string(forKey: "elevenLabsApiKey")?.isEmpty == false)
        serverOnline = hasApiKey
    }
    
    private func normalizedAppName(_ sourceApp: String?) -> String {
        let trimmed = sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed! : "Unknown"
    }
    
    private func normalizedSessionId(_ sessionId: String?) -> String? {
        let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}
