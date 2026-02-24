import Foundation

struct PiTalkRemoteServerConfig {
    var host: String
    var port: Int
    var token: String
    var replayLimit: Int
    var allowInsecureNoAuth: Bool

    static func fromEnvironmentAndDefaults() -> PiTalkRemoteServerConfig {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard

        let host: String = {
            // 1. Explicit env var
            if let envHost = env["PITALK_REMOTE_BIND"], !envHost.isEmpty {
                return envHost
            }
            // 2. UserDefaults
            if let stored = defaults.string(forKey: "remoteBindHost"), !stored.isEmpty {
                return stored
            }
            // 3. Auto-detect Tailscale — bind to it so iOS can reach us
            if let tailscaleIP = TailscaleDetector.detectTailscaleIP() {
                return tailscaleIP
            }
            // 4. Loopback fallback
            return "127.0.0.1"
        }()

        let port: Int = {
            if let envPort = env["PITALK_REMOTE_PORT"], let parsed = Int(envPort), parsed > 0 {
                return parsed
            }
            let stored = defaults.integer(forKey: "remotePort")
            return stored > 0 ? stored : 18082
        }()

        let token = env["PITALK_REMOTE_TOKEN"]
            ?? defaults.string(forKey: "remoteToken")
            ?? ""

        let allowInsecureNoAuth: Bool = {
            // Explicit env var takes priority.
            if let raw = env["PITALK_REMOTE_ALLOW_INSECURE_NO_AUTH"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return raw == "1" || raw == "true" || raw == "yes"
            }
            // Explicit UserDefaults.
            if defaults.object(forKey: "remoteAllowInsecureNoAuth") != nil {
                return defaults.bool(forKey: "remoteAllowInsecureNoAuth")
            }
            // Auto-allow on Tailscale: the network itself is authenticated
            // and encrypted (WireGuard), so token auth is optional.
            if TailscaleDetector.isTailscaleIP(host) {
                return true
            }
            return false
        }()

        return PiTalkRemoteServerConfig(
            host: host,
            port: port,
            token: token,
            replayLimit: 500,
            allowInsecureNoAuth: allowInsecureNoAuth
        )
    }

    var requiresAuth: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isLoopback: Bool {
        let normalized = host.lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost" || normalized == "::1"
    }
}

struct PiTalkRemoteSummary: Codable, Equatable {
    let total: Int
    let speaking: Int
    let queued: Int
    let idle: Int
    let color: String
    let label: String
}

struct PiTalkRemoteSession: Codable, Equatable, Identifiable {
    let id: String
    let sourceApp: String
    let sessionId: String?
    let pid: Int?
    let activity: String
    let activityLabel: String
    let currentText: String?
    let queuedCount: Int
    let voice: String?
    let lastSpokenAtMs: Int64?
    let lastSpokenText: String?
    let cwd: String?
    let tty: String?
    let mux: String?
}

struct PiTalkRemoteHistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    let timestampMs: Int64
    let text: String
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    let status: String
}

struct PiTalkRemotePlaybackState: Codable, Equatable {
    let pending: Int
    let playing: Bool
    let currentQueue: String?
}

struct PiTalkRemoteSnapshot: Codable, Equatable {
    let generatedAtMs: Int64
    let summary: PiTalkRemoteSummary
    let sessions: [PiTalkRemoteSession]
    let history: [PiTalkRemoteHistoryEntry]
    let playback: PiTalkRemotePlaybackState

    static let empty = PiTalkRemoteSnapshot(
        generatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
        summary: PiTalkRemoteSummary(total: 0, speaking: 0, queued: 0, idle: 0, color: "gray", label: "No voice activity"),
        sessions: [],
        history: [],
        playback: PiTalkRemotePlaybackState(pending: 0, playing: false, currentQueue: nil)
    )
}

enum PiTalkRemoteIncomingCommand {
    case sendText(sessionKey: String, text: String, idempotencyKey: String)
    case speak(text: String, voice: String?, sourceApp: String?, sessionId: String?, pid: Int?, idempotencyKey: String)
    case stop(scope: String?, idempotencyKey: String)
}

struct PiTalkRemoteAudioStart: Codable, Equatable {
    let streamId: String
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    let voice: String?
    let mimeType: String
}

struct PiTalkRemoteAudioChunk: Codable, Equatable {
    let streamId: String
    let chunk: Data
}

struct PiTalkRemoteAudioEnd: Codable, Equatable {
    let streamId: String
    let status: String
}

enum PiTalkRemoteAudioMirrorEvent {
    case start(PiTalkRemoteAudioStart)
    case chunk(PiTalkRemoteAudioChunk)
    case end(PiTalkRemoteAudioEnd)
}

struct PiTalkRemoteCommandResult {
    let ok: Bool
    let code: String?
    let message: String?
    let payload: [String: Any]

    static func success(payload: [String: Any] = [:]) -> PiTalkRemoteCommandResult {
        PiTalkRemoteCommandResult(ok: true, code: nil, message: nil, payload: payload)
    }

    static func failure(code: String, message: String) -> PiTalkRemoteCommandResult {
        PiTalkRemoteCommandResult(ok: false, code: code, message: message, payload: [:])
    }
}

typealias PiTalkRemoteSnapshotProvider = () -> PiTalkRemoteSnapshot
typealias PiTalkRemoteCommandHandler = (_ command: PiTalkRemoteIncomingCommand, _ completion: @escaping (PiTalkRemoteCommandResult) -> Void) -> Void

func pitalkRemoteCurrentTimestampMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

func pitalkRemoteJsonObject<T: Encodable>(_ value: T) -> Any? {
    do {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        return nil
    }
}
