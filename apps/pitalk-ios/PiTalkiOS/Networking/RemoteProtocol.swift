import Foundation

struct RemoteEnvelope<T: Codable>: Codable {
    let type: String
    let name: String?
    let requestId: String?
    let idempotencyKey: String?
    let seq: Int64?
    let ts: Int64?
    let payload: T?
}

struct RemoteAuthHelloPayload: Codable {
    let token: String
    let clientName: String
    let clientVersion: String
    let resumeFromSeq: Int64?
}

struct RemoteSessionSummary: Codable, Equatable {
    let total: Int
    let speaking: Int
    let queued: Int
    let idle: Int
    let color: String
    let label: String
}

struct RemoteSession: Codable, Equatable, Identifiable {
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

struct RemoteHistoryEntry: Codable, Equatable, Identifiable {
    let id: String
    let timestampMs: Int64
    let text: String
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    let status: String
}

struct RemotePlaybackState: Codable, Equatable {
    let pending: Int
    let playing: Bool
    let currentQueue: String?
}

struct RemoteSnapshot: Codable, Equatable {
    let generatedAtMs: Int64
    let summary: RemoteSessionSummary
    let sessions: [RemoteSession]
    let history: [RemoteHistoryEntry]
    let playback: RemotePlaybackState

    static let empty = RemoteSnapshot(
        generatedAtMs: 0,
        summary: RemoteSessionSummary(total: 0, speaking: 0, queued: 0, idle: 0, color: "gray", label: "No data"),
        sessions: [],
        history: [],
        playback: RemotePlaybackState(pending: 0, playing: false, currentQueue: nil)
    )
}

struct RemoteSendTextPayload: Codable {
    let sessionKey: String
    let text: String
}

struct RemoteSendScreenshotPayload: Codable {
    let sessionKey: String
    let imageBase64: String
    let mimeType: String
    let note: String?
}

struct RemoteSpeakPayload: Codable {
    let text: String
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
}

struct RemoteStopPayload: Codable {
    let scope: String
}

struct RemoteAudioSetStreamPayload: Codable {
    let enabled: Bool
}

struct RemoteAudioStartEvent: Codable {
    let streamId: String
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
    let voice: String?
    let mimeType: String
}

struct RemoteAudioChunkEvent: Codable {
    let streamId: String
    let chunk: Data
}

struct RemoteAudioEndEvent: Codable {
    let streamId: String
    let status: String
}

struct RemoteErrorPayload: Codable {
    let code: String
    let message: String
}

struct RemoteServerHelloPayload: Codable {
    let server: ServerInfo
    let requiresAuth: Bool
    let eventSeq: Int64

    struct ServerInfo: Codable {
        let name: String
        let version: String
    }
}

struct RemoteAuthAckPayload: Codable {
    let serverVersion: String
    let sessionId: String
    let eventSeq: Int64
}
