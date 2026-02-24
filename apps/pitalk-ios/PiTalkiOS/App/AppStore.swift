import Foundation
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var host: String = ""
    @Published var port: String = "18082"
    @Published var token: String = ""
    @Published var selectedSessionId: String?
    @Published var draftText: String = ""
    /// Locally-tracked messages sent by the user (keyed by session id).
    @Published var sentMessages: [String: [SentMessage]] = [:]

    let socket = RemoteSocketClient()
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Forward nested socket updates so SwiftUI views observing AppStore
        // re-render for connection/snapshot changes.
        socket.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        loadSettings()
    }

    func connect() {
        guard let url = websocketURL else { return }
        saveSettings()
        socket.connect(url: url, token: token)
    }

    func disconnect() {
        socket.disconnect()
    }

    func reconnect() {
        socket.reconnectNow()
    }

    func stopAll() {
        Task {
            try? await socket.stopAll()
        }
    }

    func sendDraftToSelectedSession() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let sessionId = selectedSessionId else { return }

        // Track locally so it shows in the session timeline
        let msg = SentMessage(text: text)
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

    var websocketURL: URL? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return nil }

        let cleanPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let numericPort = Int(cleanPort), numericPort > 0 else { return nil }

        return URL(string: "ws://\(cleanHost):\(numericPort)/ws")
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        host = defaults.string(forKey: "pitalk.remote.host") ?? ""
        let storedPort = defaults.integer(forKey: "pitalk.remote.port")
        port = storedPort > 0 ? String(storedPort) : "18082"
        token = defaults.string(forKey: "pitalk.remote.token") ?? ""
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "pitalk.remote.host")
        defaults.set(Int(port), forKey: "pitalk.remote.port")
        defaults.set(token, forKey: "pitalk.remote.token")
    }
}

/// A message sent by the user from the iOS app.
struct SentMessage: Identifiable {
    let id = UUID()
    let text: String
    let timestampMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
}
