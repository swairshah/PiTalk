import Foundation
import Combine
import SwiftUI

// MARK: - Server Profile

struct ServerProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var host: String
    var port: String
    var token: String

    var displayName: String {
        name.isEmpty ? host : name
    }

    var websocketURL: URL? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return nil }
        let cleanPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericPort = Int(cleanPort), numericPort > 0 else { return nil }
        return URL(string: "ws://\(cleanHost):\(numericPort)/ws")
    }
}

// MARK: - App Store

@MainActor
final class AppStore: ObservableObject {
    @Published var profiles: [ServerProfile] = []
    @Published var activeProfileId: UUID?
    @Published var selectedSessionId: String?
    @Published var draftText: String = ""
    @Published var sentMessages: [String: [SentMessage]] = [:]
    @Published var remoteAudioStreamingRequested: Bool = false
    /// Set by deep link from Live Activity tap — drives navigation.
    @Published var deepLinkSessionId: String?

    private var appIsActive = true

    let socket = RemoteSocketClient()
    private var cancellables = Set<AnyCancellable>()

    /// The currently active profile (if any).
    var activeProfile: ServerProfile? {
        profiles.first(where: { $0.id == activeProfileId })
    }

    init() {
        socket.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Drive Live Activities from snapshot updates.
        socket.$snapshot
            .removeDuplicates()
            .sink { [weak self] snapshot in
                guard let self else { return }
                let serverName = self.activeProfile?.displayName ?? "PiTalk"
                LiveActivityManager.shared.reconcile(
                    sessions: snapshot.sessions,
                    serverName: serverName
                )
            }
            .store(in: &cancellables)

        socket.$connectionState
            .sink { [weak self] _ in
                self?.syncAudioStreamingState()
            }
            .store(in: &cancellables)

        loadProfiles()
        migrateFromLegacySettings()
    }

    // MARK: - Profile Management

    func addProfile(_ profile: ServerProfile) {
        profiles.append(profile)
        saveProfiles()
    }

    func updateProfile(_ profile: ServerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        saveProfiles()
        // If we updated the active profile, reconnect with new settings.
        if profile.id == activeProfileId {
            connectToProfile(profile)
        }
    }

    func deleteProfile(_ profile: ServerProfile) {
        profiles.removeAll(where: { $0.id == profile.id })
        if activeProfileId == profile.id {
            disconnect()
            activeProfileId = nil
        }
        saveProfiles()
    }

    func connectToProfile(_ profile: ServerProfile) {
        guard let url = profile.websocketURL else { return }
        activeProfileId = profile.id
        sentMessages.removeAll()
        selectedSessionId = nil
        remoteAudioStreamingRequested = false
        socket.resetAudioStreamingPreference()
        saveProfiles()
        socket.connect(url: url, token: profile.token)
    }

    func disconnect() {
        remoteAudioStreamingRequested = false
        socket.disconnect()
        LiveActivityManager.shared.endAll()
    }

    func reconnect() {
        if let profile = activeProfile {
            connectToProfile(profile)
        } else {
            socket.reconnectNow()
        }
    }

    func stopAll() {
        Task { try? await socket.stopAll() }
    }

    func setRemoteAudioStreaming(enabled: Bool) {
        remoteAudioStreamingRequested = enabled
        syncAudioStreamingState()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        appIsActive = (phase == .active)
        syncAudioStreamingState()
    }

    private func syncAudioStreamingState() {
        guard case .connected = socket.connectionState else { return }
        let shouldEnable = remoteAudioStreamingRequested && appIsActive
        if socket.audioStreamEnabled == shouldEnable { return }

        Task {
            do {
                try await socket.setAudioStreaming(enabled: shouldEnable)
            } catch {
                // Keep user preference; we'll retry on next state change/reconnect.
            }
        }
    }

    func sendDraftToSelectedSession() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let sessionId = selectedSessionId else { return }

        let msg = SentMessage(kind: .text(text))
        sentMessages[sessionId, default: []].append(msg)

        Task {
            do {
                try await socket.sendText(sessionKey: sessionId, text: text)
                draftText = ""
            } catch {
                // Keep text in field so user can retry.
            }
        }
    }

    func sendScreenshotToSelectedSession(imageData: Data, note: String? = nil) async {
        guard let sessionId = selectedSessionId else { return }

        do {
            try await socket.sendScreenshot(
                sessionKey: sessionId,
                imageData: imageData,
                mimeType: "image/jpeg",
                note: note
            )

            let marker = SentMessage(kind: .screenshot(note: note))
            sentMessages[sessionId, default: []].append(marker)
        } catch {
            // Keep silent here; connection/error state is already surfaced by socket.
        }
    }

    // MARK: - Persistence

    private static let profilesKey = "pitalk.profiles"
    private static let activeProfileKey = "pitalk.activeProfileId"

    private func loadProfiles() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
        if let idString = defaults.string(forKey: Self.activeProfileKey),
           let id = UUID(uuidString: idString) {
            activeProfileId = id
        }
    }

    private func saveProfiles() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
        defaults.set(activeProfileId?.uuidString, forKey: Self.activeProfileKey)
    }

    /// Migrate from the old single-server settings to a profile.
    private func migrateFromLegacySettings() {
        let defaults = UserDefaults.standard
        let legacyHost = defaults.string(forKey: "pitalk.remote.host") ?? ""
        guard !legacyHost.isEmpty, profiles.isEmpty else { return }

        let legacyPort = defaults.integer(forKey: "pitalk.remote.port")
        let legacyToken = defaults.string(forKey: "pitalk.remote.token") ?? ""

        let profile = ServerProfile(
            name: "My Mac",
            host: legacyHost,
            port: legacyPort > 0 ? String(legacyPort) : "18082",
            token: legacyToken
        )
        profiles.append(profile)
        activeProfileId = profile.id
        saveProfiles()

        // Clean up legacy keys
        defaults.removeObject(forKey: "pitalk.remote.host")
        defaults.removeObject(forKey: "pitalk.remote.port")
        defaults.removeObject(forKey: "pitalk.remote.token")
    }
}

// MARK: - Sent Message

struct SentMessage: Identifiable {
    enum Kind {
        case text(String)
        case screenshot(note: String?)
    }

    let id = UUID()
    let kind: Kind
    let timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)

    var text: String {
        switch kind {
        case .text(let value):
            return value
        case .screenshot(let note):
            if let note, !note.isEmpty {
                return "📷 Screenshot sent — \(note)"
            }
            return "📷 Screenshot sent"
        }
    }
}
