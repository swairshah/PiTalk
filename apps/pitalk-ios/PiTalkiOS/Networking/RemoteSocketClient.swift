import Foundation
import Combine

@MainActor
final class RemoteSocketClient: ObservableObject {
    enum ConnectionState: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting
        case failed(String)
    }

    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var snapshot: RemoteSnapshot = .empty
    @Published private(set) var lastError: String?
    @Published private(set) var lastSeq: Int64 = 0

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectAttempts = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var pendingRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var snapshotPollTask: Task<Void, Never>?

    private(set) var endpointURL: URL?
    private(set) var authToken: String = ""

    func connect(url: URL, token: String) {
        endpointURL = url
        authToken = token
        reconnectAttempts = 0
        openSocket(isReconnect: false)
    }

    func disconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        snapshotPollTask?.cancel()
        snapshotPollTask = nil
        pendingRequests.values.forEach { continuation in
            continuation.resume(throwing: NSError(domain: "RemoteSocket", code: -1, userInfo: [NSLocalizedDescriptionKey: "Disconnected"]))
        }
        pendingRequests.removeAll()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        connectionState = .idle
    }

    func reconnectNow() {
        reconnectAttempts = 0
        openSocket(isReconnect: true)
    }

    private func openSocket(isReconnect: Bool) {
        guard let endpointURL else {
            connectionState = .failed("Missing endpoint URL")
            return
        }

        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        snapshotPollTask?.cancel()
        snapshotPollTask = nil

        connectionState = isReconnect ? .reconnecting : .connecting

        session?.invalidateAndCancel()
        let session = URLSession(configuration: .default)
        self.session = session

        let task = session.webSocketTask(with: endpointURL)
        self.task = task
        task.resume()

        receiveLoop()

        Task {
            do {
                try await sendAuthHello()

                // Mark connected as soon as auth handshake succeeds so UI doesn't
                // stay stuck in "Connecting" if snapshot fetch is delayed.
                reconnectAttempts = 0
                connectionState = .connected
                startSnapshotPolling()

                // Snapshot fetch is best-effort; live events can still hydrate state.
                do {
                    _ = try await fetchSnapshot()
                } catch {
                    lastError = "Snapshot refresh failed: \(error.localizedDescription)"
                }
            } catch {
                failAndScheduleReconnect(error)
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure(let error):
                    self.failAndScheduleReconnect(error)

                case .success(let message):
                    self.handleMessage(message)
                    self.receiveLoop()
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let binaryData):
            data = binaryData
        case .string(let string):
            data = Data(string.utf8)
        @unknown default:
            return
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let frame = object as? [String: Any],
            let type = frame["type"] as? String
        else {
            return
        }

        if let seq = frame["seq"] as? Int64 {
            lastSeq = max(lastSeq, seq)
        } else if let seqInt = frame["seq"] as? Int {
            lastSeq = max(lastSeq, Int64(seqInt))
        }

        switch type {
        case "ack":
            resolvePendingRequest(frame)
        case "error":
            resolvePendingError(frame)
        case "event":
            handleEvent(frame)
        case "ping":
            sendPong(for: frame)
        default:
            break
        }
    }

    private func handleEvent(_ frame: [String: Any]) {
        // Any authenticated event implies we're connected.
        if connectionState != .connected {
            connectionState = .connected
        }

        guard let name = frame["name"] as? String else { return }
        let payload = frame["payload"]

        switch name {
        case "sessions.updated":
            if let payload, let snapshot: RemoteSnapshot = decode(payload) {
                self.snapshot = snapshot
            }

        case "history.appended":
            if let payload, let entry: RemoteHistoryEntry = decode(payload) {
                var newHistory = snapshot.history
                newHistory.insert(entry, at: 0)
                if newHistory.count > 250 {
                    newHistory.removeLast(newHistory.count - 250)
                }
                snapshot = RemoteSnapshot(
                    generatedAtMs: snapshot.generatedAtMs,
                    summary: snapshot.summary,
                    sessions: snapshot.sessions,
                    history: newHistory,
                    playback: snapshot.playback
                )
            }

        case "playback.state":
            if let payload, let playback: RemotePlaybackState = decode(payload) {
                snapshot = RemoteSnapshot(
                    generatedAtMs: snapshot.generatedAtMs,
                    summary: snapshot.summary,
                    sessions: snapshot.sessions,
                    history: snapshot.history,
                    playback: playback
                )
            }

        default:
            break
        }
    }

    private func sendPong(for frame: [String: Any]) {
        var payload: [String: Any] = [
            "type": "pong",
            "ts": Int64(Date().timeIntervalSince1970 * 1000),
        ]
        if let requestId = frame["requestId"] as? String {
            payload["requestId"] = requestId
        }
        sendRaw(payload)
    }

    private func sendAuthHello() async throws {
        let payload = RemoteAuthHelloPayload(
            token: authToken,
            clientName: "pitalk-ios",
            clientVersion: "0.1.0",
            resumeFromSeq: lastSeq > 0 ? lastSeq : nil
        )
        _ = try await sendCommand(name: "auth.hello", payload: payload, idempotencyKey: nil)
    }

    func fetchSnapshot() async throws -> RemoteSnapshot {
        let response = try await sendCommand(name: "sessions.snapshot.get", payload: Optional<String>.none, idempotencyKey: nil)
        guard let snapshot: RemoteSnapshot = decode(response) else {
            throw NSError(domain: "RemoteSocket", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid snapshot response"])
        }
        self.snapshot = snapshot
        return snapshot
    }

    func sendText(sessionKey: String, text: String) async throws {
        let payload = RemoteSendTextPayload(sessionKey: sessionKey, text: text)
        _ = try await sendCommand(name: "session.sendText", payload: payload, idempotencyKey: UUID().uuidString)
    }

    func speak(text: String, voice: String? = nil) async throws {
        let payload = RemoteSpeakPayload(text: text, voice: voice, sourceApp: "pitalk-ios", sessionId: "iphone", pid: nil)
        _ = try await sendCommand(name: "tts.speak", payload: payload, idempotencyKey: UUID().uuidString)
    }

    func stopAll() async throws {
        let payload = RemoteStopPayload(scope: "global")
        _ = try await sendCommand(name: "tts.stop", payload: payload, idempotencyKey: UUID().uuidString)
    }

    private func sendCommand<T: Codable>(name: String, payload: T?, idempotencyKey: String?) async throws -> [String: Any] {
        let requestId = UUID().uuidString

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation

            var frame: [String: Any] = [
                "type": "cmd",
                "name": name,
                "requestId": requestId,
            ]

            if let idempotencyKey {
                frame["idempotencyKey"] = idempotencyKey
            }

            if let payload,
               let payloadData = try? JSONEncoder().encode(payload),
               let payloadObject = try? JSONSerialization.jsonObject(with: payloadData)
            {
                frame["payload"] = payloadObject
            } else {
                frame["payload"] = [:]
            }

            sendRaw(frame)
        }
    }

    private func sendRaw(_ frame: [String: Any]) {
        guard let task else { return }
        guard JSONSerialization.isValidJSONObject(frame) else { return }

        do {
            let data = try JSONSerialization.data(withJSONObject: frame)
            let text = String(decoding: data, as: UTF8.self)
            task.send(.string(text)) { [weak self] error in
                guard let self, let error else { return }
                Task { @MainActor in
                    self.failAndScheduleReconnect(error)
                }
            }
        } catch {
            failAndScheduleReconnect(error)
        }
    }

    private func resolvePendingRequest(_ frame: [String: Any]) {
        guard let requestId = frame["requestId"] as? String,
              let continuation = pendingRequests.removeValue(forKey: requestId)
        else {
            return
        }

        let payload = frame["payload"] as? [String: Any] ?? [:]
        continuation.resume(returning: payload)
    }

    private func resolvePendingError(_ frame: [String: Any]) {
        guard let requestId = frame["requestId"] as? String,
              let continuation = pendingRequests.removeValue(forKey: requestId)
        else {
            return
        }

        let payload = frame["payload"] as? [String: Any]
        let message = payload?["message"] as? String ?? "Unknown remote error"
        continuation.resume(throwing: NSError(domain: "RemoteSocket", code: -3, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func failAndScheduleReconnect(_ error: Error) {
        lastError = error.localizedDescription
        connectionState = .failed(error.localizedDescription)

        snapshotPollTask?.cancel()
        snapshotPollTask = nil
        reconnectWorkItem?.cancel()

        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 15)

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.openSocket(isReconnect: true)
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startSnapshotPolling() {
        snapshotPollTask?.cancel()
        snapshotPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                if case .connected = self.connectionState {
                    do {
                        _ = try await self.fetchSnapshot()
                    } catch {
                        self.lastError = "Snapshot poll failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func decode<T: Codable>(_ object: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
