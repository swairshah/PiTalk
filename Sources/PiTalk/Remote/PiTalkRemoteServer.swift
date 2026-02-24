import CryptoKit
import Foundation
import Network

private final class PiTalkRemotePeer {
    let id = UUID()
    let connection: NWConnection
    var handshakeBuffer = Data()
    var frameBuffer = Data()
    var handshakeComplete = false
    var authenticated = false
    var awaitingPongCount = 0
    var idempotentAckByKey: [String: [String: Any]] = [:]

    init(connection: NWConnection) {
        self.connection = connection
    }
}

private struct PiTalkRemoteStoredEvent {
    let seq: Int64
    let frame: [String: Any]
}

final class PiTalkRemoteServer {
    private let config: PiTalkRemoteServerConfig
    private let queue = DispatchQueue(label: "pitalk.remote.server")

    private var listener: NWListener?
    private var peers: [UUID: PiTalkRemotePeer] = [:]
    private var eventSeq: Int64 = 0
    private var replayLog: [PiTalkRemoteStoredEvent] = []
    private var heartbeatTimer: DispatchSourceTimer?

    private let snapshotProvider: PiTalkRemoteSnapshotProvider
    private let commandHandler: PiTalkRemoteCommandHandler

    init(
        config: PiTalkRemoteServerConfig,
        snapshotProvider: @escaping PiTalkRemoteSnapshotProvider,
        commandHandler: @escaping PiTalkRemoteCommandHandler
    ) {
        self.config = config
        self.snapshotProvider = snapshotProvider
        self.commandHandler = commandHandler
    }

    func start() throws {
        guard listener == nil else { return }
        if !config.isLoopback && !config.requiresAuth && !config.allowInsecureNoAuth {
            throw NSError(
                domain: "PiTalkRemote",
                code: 401,
                userInfo: [
                    NSLocalizedDescriptionKey: "Refusing non-loopback remote server without token auth (set PITALK_REMOTE_TOKEN, or explicitly set PITALK_REMOTE_ALLOW_INSECURE_NO_AUTH=1 for local dev only)",
                ]
            )
        }

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(config.port)) else {
            throw NSError(domain: "PiTalkRemote", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(config.port)"])
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Use a dual-stack wildcard listener for 0.0.0.0/::/* so tailnet IPv4 clients
        // can connect reliably.
        let normalizedHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let listener: NWListener
        if normalizedHost == "0.0.0.0" || normalizedHost == "::" || normalizedHost == "*" {
            listener = try NWListener(using: parameters, on: nwPort)
        } else {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(config.host), port: nwPort)
            listener = try NWListener(using: parameters)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("PiTalk Remote: listening on \(self.config.host):\(self.config.port)")
            case .failed(let error):
                print("PiTalk Remote: listener failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.accept(connection: connection)
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        startHeartbeatLoop()
    }

    func stop() {
        queue.async {
            self.stopLocked()
        }
    }

    private func stopLocked() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        peers.values.forEach { $0.connection.cancel() }
        peers.removeAll()

        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        replayLog.removeAll()
        eventSeq = 0
    }

    private func accept(connection: NWConnection) {
        let peer = PiTalkRemotePeer(connection: connection)
        peers[peer.id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            self.queue.async {
                switch state {
                case .failed, .cancelled:
                    self.drop(peer: peer)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receiveHandshake(for: peer)
    }

    private func drop(peer: PiTalkRemotePeer) {
        peer.connection.cancel()
        peers.removeValue(forKey: peer.id)
    }

    private func receiveHandshake(for peer: PiTalkRemotePeer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            self.queue.async {
                if error != nil || isComplete {
                    self.drop(peer: peer)
                    return
                }

                if let data {
                    peer.handshakeBuffer.append(data)
                }

                guard let range = peer.handshakeBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                    self.receiveHandshake(for: peer)
                    return
                }

                let headerData = peer.handshakeBuffer.subdata(in: 0..<range.upperBound)
                guard let headers = String(data: headerData, encoding: .utf8) else {
                    self.sendHttpFailureAndDrop(peer: peer, status: "400 Bad Request")
                    return
                }

                self.finishHandshake(peer: peer, rawHeaders: headers)
            }
        }
    }

    private func finishHandshake(peer: PiTalkRemotePeer, rawHeaders: String) {
        let lines = rawHeaders.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let requestLine = lines.first, requestLine.lowercased().hasPrefix("get ") else {
            sendHttpFailureAndDrop(peer: peer, status: "400 Bad Request")
            return
        }

        var headerMap: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<split]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headerMap[key] = value
        }

        guard let upgrade = headerMap["upgrade"], upgrade.lowercased() == "websocket" else {
            sendHttpFailureAndDrop(peer: peer, status: "426 Upgrade Required")
            return
        }

        guard let wsKey = headerMap["sec-websocket-key"], !wsKey.isEmpty else {
            sendHttpFailureAndDrop(peer: peer, status: "400 Bad Request")
            return
        }

        let accept = websocketAccept(key: wsKey)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "\r\n",
        ].joined(separator: "\r\n")

        peer.connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self, weak peer] sendError in
            guard let self, let peer else { return }
            self.queue.async {
                if sendError != nil {
                    self.drop(peer: peer)
                    return
                }
                peer.handshakeComplete = true
                self.sendHelloBanner(to: peer)
                self.receiveFrames(for: peer)
            }
        })
    }

    private func sendHelloBanner(to peer: PiTalkRemotePeer) {
        let payload: [String: Any] = [
            "server": [
                "name": "PiTalkRemote",
                "version": "0.1.0",
            ],
            "requiresAuth": config.requiresAuth,
            "eventSeq": eventSeq,
        ]
        sendJSON([
            "type": "event",
            "name": "server.hello",
            "seq": eventSeq,
            "ts": pitalkRemoteCurrentTimestampMs(),
            "payload": payload,
        ], to: peer)
    }

    private func sendHttpFailureAndDrop(peer: PiTalkRemotePeer, status: String) {
        let body = "{\"ok\":false,\"error\":\"\(status)\"}\n"
        let response = [
            "HTTP/1.1 \(status)",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Connection: close",
            "\r\n\(body)",
        ].joined(separator: "\r\n")

        peer.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            peer.connection.cancel()
        })
        peers.removeValue(forKey: peer.id)
    }

    private func websocketAccept(key: String) -> String {
        let concatenated = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(concatenated.utf8))
        return Data(digest).base64EncodedString()
    }

    private func receiveFrames(for peer: PiTalkRemotePeer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            self.queue.async {
                if error != nil || isComplete {
                    self.drop(peer: peer)
                    return
                }
                if let data {
                    peer.frameBuffer.append(data)
                    self.parseFrames(for: peer)
                }
                self.receiveFrames(for: peer)
            }
        }
    }

    private func parseFrames(for peer: PiTalkRemotePeer) {
        while true {
            guard let parsed = readWebSocketFrame(from: &peer.frameBuffer) else {
                return
            }

            switch parsed.opcode {
            case 0x1, 0x2: // text or binary(json)
                guard let text = String(data: parsed.payload, encoding: .utf8) else {
                    sendProtocolError(to: peer, code: "BAD_REQUEST", message: "invalid utf8 frame")
                    continue
                }
                handleTextMessage(text, from: peer)

            case 0x8: // close
                sendCloseFrame(to: peer)
                drop(peer: peer)
                return

            case 0x9: // ping
                sendFrame(opcode: 0xA, payload: parsed.payload, to: peer)

            case 0xA: // pong
                peer.awaitingPongCount = 0

            default:
                break
            }
        }
    }

    private func handleTextMessage(_ text: String, from peer: PiTalkRemotePeer) {
        guard
            let data = text.data(using: .utf8),
            let rawObject = try? JSONSerialization.jsonObject(with: data),
            let object = rawObject as? [String: Any],
            let type = object["type"] as? String
        else {
            sendProtocolError(to: peer, code: "BAD_REQUEST", message: "invalid json frame")
            return
        }

        if type == "ping" {
            sendJSON([
                "type": "pong",
                "name": object["name"] as? String ?? "ping",
                "requestId": (object["requestId"] as? String) as Any,
                "ts": pitalkRemoteCurrentTimestampMs(),
                "payload": object["payload"] ?? [:],
            ], to: peer)
            return
        }

        guard type == "cmd" else {
            sendProtocolError(to: peer, code: "BAD_REQUEST", message: "unsupported frame type")
            return
        }

        let name = object["name"] as? String ?? ""
        let requestId = object["requestId"] as? String
        let payload = object["payload"] as? [String: Any] ?? [:]
        let idempotencyKey = object["idempotencyKey"] as? String

        guard let requestId, !requestId.isEmpty else {
            sendProtocolError(to: peer, code: "BAD_REQUEST", message: "requestId is required")
            return
        }

        if !peer.authenticated && name != "auth.hello" {
            sendError(name: name, requestId: requestId, code: "AUTH_REQUIRED", message: "authenticate with auth.hello first", to: peer)
            return
        }

        switch name {
        case "auth.hello":
            handleAuthHello(payload: payload, requestId: requestId, peer: peer)

        case "sessions.snapshot.get":
            let snapshot = snapshotProvider()
            let snapshotPayload = (pitalkRemoteJsonObject(snapshot) as? [String: Any]) ?? [:]
            sendAck(name: name, requestId: requestId, payload: snapshotPayload, to: peer)

        case "session.sendText":
            guard let idempotencyKey, !idempotencyKey.isEmpty else {
                sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "idempotencyKey is required", to: peer)
                return
            }
            if let previous = peer.idempotentAckByKey[idempotencyKey] {
                sendJSON(previous, to: peer)
                return
            }
            guard let sessionKey = payload["sessionKey"] as? String, let text = payload["text"] as? String else {
                sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "sessionKey and text are required", to: peer)
                return
            }
            let command = PiTalkRemoteIncomingCommand.sendText(sessionKey: sessionKey, text: text, idempotencyKey: idempotencyKey)
            handleAsyncCommand(command, name: name, requestId: requestId, idempotencyKey: idempotencyKey, peer: peer)

        case "tts.speak":
            guard let idempotencyKey, !idempotencyKey.isEmpty else {
                sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "idempotencyKey is required", to: peer)
                return
            }
            if let previous = peer.idempotentAckByKey[idempotencyKey] {
                sendJSON(previous, to: peer)
                return
            }
            guard let text = payload["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "text is required", to: peer)
                return
            }
            let voice = payload["voice"] as? String
            let sourceApp = payload["sourceApp"] as? String
            let sessionId = payload["sessionId"] as? String
            let pid = payload["pid"] as? Int
            let command = PiTalkRemoteIncomingCommand.speak(
                text: text,
                voice: voice,
                sourceApp: sourceApp,
                sessionId: sessionId,
                pid: pid,
                idempotencyKey: idempotencyKey
            )
            handleAsyncCommand(command, name: name, requestId: requestId, idempotencyKey: idempotencyKey, peer: peer)

        case "tts.stop":
            guard let idempotencyKey, !idempotencyKey.isEmpty else {
                sendError(name: name, requestId: requestId, code: "BAD_REQUEST", message: "idempotencyKey is required", to: peer)
                return
            }
            if let previous = peer.idempotentAckByKey[idempotencyKey] {
                sendJSON(previous, to: peer)
                return
            }
            let scope = payload["scope"] as? String
            let command = PiTalkRemoteIncomingCommand.stop(scope: scope, idempotencyKey: idempotencyKey)
            handleAsyncCommand(command, name: name, requestId: requestId, idempotencyKey: idempotencyKey, peer: peer)

        default:
            sendError(name: name, requestId: requestId, code: "UNKNOWN_COMMAND", message: "unknown command: \(name)", to: peer)
        }
    }

    private func handleAuthHello(payload: [String: Any], requestId: String, peer: PiTalkRemotePeer) {
        let providedToken = (payload["token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if config.requiresAuth && providedToken != config.token {
            sendError(name: "auth.hello", requestId: requestId, code: "AUTH_INVALID", message: "invalid token", to: peer)
            return
        }

        peer.authenticated = true

        let resumeFromSeq = payload["resumeFromSeq"] as? Int64
        let ackPayload: [String: Any] = [
            "serverVersion": "0.1.0",
            "sessionId": peer.id.uuidString,
            "eventSeq": eventSeq,
            "replay": [
                "requestedFromSeq": resumeFromSeq as Any,
            ],
        ]

        sendAck(name: "auth.hello", requestId: requestId, payload: ackPayload, to: peer)

        if let resumeFromSeq {
            replayEvents(from: resumeFromSeq, to: peer)
        } else {
            sendSnapshotEvent(to: peer)
        }
    }

    private func replayEvents(from seq: Int64, to peer: PiTalkRemotePeer) {
        let missing = replayLog.filter { $0.seq > seq }
        if missing.isEmpty {
            sendSnapshotEvent(to: peer)
            return
        }

        if let first = missing.first, first.seq != seq + 1 {
            emitEvent(name: "stream.reset", payload: ["reason": "replay-window-exceeded"], only: peer)
            sendSnapshotEvent(to: peer)
            return
        }

        for event in missing {
            sendJSON(event.frame, to: peer)
        }
    }

    private func sendSnapshotEvent(to peer: PiTalkRemotePeer) {
        let snapshot = snapshotProvider()
        let payload = (pitalkRemoteJsonObject(snapshot) as? [String: Any]) ?? [:]
        emitEvent(name: "sessions.updated", payload: payload, only: peer)
    }

    private func handleAsyncCommand(
        _ command: PiTalkRemoteIncomingCommand,
        name: String,
        requestId: String,
        idempotencyKey: String,
        peer: PiTalkRemotePeer
    ) {
        commandHandler(command) { [weak self, weak peer] result in
            guard let self, let peer else { return }
            self.queue.async {
                guard self.peers[peer.id] != nil else { return }

                if result.ok {
                    let ack = self.makeAckFrame(name: name, requestId: requestId, payload: result.payload)
                    peer.idempotentAckByKey[idempotencyKey] = ack
                    self.sendJSON(ack, to: peer)
                } else {
                    self.sendError(
                        name: name,
                        requestId: requestId,
                        code: result.code ?? "INTERNAL_ERROR",
                        message: result.message ?? "command failed",
                        to: peer
                    )
                }
            }
        }
    }

    private func makeAckFrame(name: String, requestId: String, payload: [String: Any]) -> [String: Any] {
        [
            "type": "ack",
            "name": name,
            "requestId": requestId,
            "ts": pitalkRemoteCurrentTimestampMs(),
            "payload": payload,
        ]
    }

    private func sendAck(name: String, requestId: String, payload: [String: Any], to peer: PiTalkRemotePeer) {
        sendJSON(makeAckFrame(name: name, requestId: requestId, payload: payload), to: peer)
    }

    private func sendError(name: String, requestId: String, code: String, message: String, to peer: PiTalkRemotePeer) {
        sendJSON([
            "type": "error",
            "name": name,
            "requestId": requestId,
            "ts": pitalkRemoteCurrentTimestampMs(),
            "payload": [
                "code": code,
                "message": message,
            ],
        ], to: peer)
    }

    private func sendProtocolError(to peer: PiTalkRemotePeer, code: String, message: String) {
        sendJSON([
            "type": "error",
            "name": "protocol",
            "requestId": UUID().uuidString,
            "ts": pitalkRemoteCurrentTimestampMs(),
            "payload": [
                "code": code,
                "message": message,
            ],
        ], to: peer)
    }

    func publishSessionsUpdated(_ snapshot: PiTalkRemoteSnapshot) {
        let payload = (pitalkRemoteJsonObject(snapshot) as? [String: Any]) ?? [:]
        queue.async {
            self.emitEvent(name: "sessions.updated", payload: payload)
        }
    }

    func publishPlaybackState(_ playback: PiTalkRemotePlaybackState) {
        let payload = (pitalkRemoteJsonObject(playback) as? [String: Any]) ?? [:]
        queue.async {
            self.emitEvent(name: "playback.state", payload: payload)
        }
    }

    func publishHistoryAppended(_ entry: PiTalkRemoteHistoryEntry) {
        let payload = (pitalkRemoteJsonObject(entry) as? [String: Any]) ?? [:]
        queue.async {
            self.emitEvent(name: "history.appended", payload: payload)
        }
    }

    private func emitEvent(name: String, payload: [String: Any], only peer: PiTalkRemotePeer? = nil) {
        eventSeq += 1
        let frame: [String: Any] = [
            "type": "event",
            "name": name,
            "seq": eventSeq,
            "ts": pitalkRemoteCurrentTimestampMs(),
            "payload": payload,
        ]

        replayLog.append(PiTalkRemoteStoredEvent(seq: eventSeq, frame: frame))
        if replayLog.count > config.replayLimit {
            replayLog.removeFirst(replayLog.count - config.replayLimit)
        }

        if let peer {
            guard peer.authenticated else { return }
            sendJSON(frame, to: peer)
            return
        }

        for peer in peers.values where peer.authenticated {
            sendJSON(frame, to: peer)
        }
    }

    private func sendJSON(_ object: [String: Any], to peer: PiTalkRemotePeer) {
        guard JSONSerialization.isValidJSONObject(object) else {
            return
        }

        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }

        sendFrame(opcode: 0x1, payload: data, to: peer)
    }

    private func sendCloseFrame(to peer: PiTalkRemotePeer) {
        sendFrame(opcode: 0x8, payload: Data(), to: peer)
    }

    private func sendFrame(opcode: UInt8, payload: Data, to peer: PiTalkRemotePeer) {
        var frame = Data()
        frame.append(0x80 | opcode) // FIN + opcode

        let payloadLength = payload.count
        if payloadLength < 126 {
            frame.append(UInt8(payloadLength))
        } else if payloadLength <= 0xFFFF {
            frame.append(126)
            var len = UInt16(payloadLength).bigEndian
            withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        } else {
            frame.append(127)
            var len = UInt64(payloadLength).bigEndian
            withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        }

        frame.append(payload)

        peer.connection.send(content: frame, completion: .contentProcessed { [weak self, weak peer] error in
            guard let self, let peer else { return }
            if error != nil {
                self.queue.async {
                    self.drop(peer: peer)
                }
            }
        })
    }

    private func startHeartbeatLoop() {
        heartbeatTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            self?.sendHeartbeats()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func sendHeartbeats() {
        for peer in peers.values where peer.authenticated {
            peer.awaitingPongCount += 1
            if peer.awaitingPongCount > 2 {
                sendCloseFrame(to: peer)
                drop(peer: peer)
                continue
            }
            sendFrame(opcode: 0x9, payload: Data("hb".utf8), to: peer)
        }
    }

    private func readWebSocketFrame(from buffer: inout Data) -> (opcode: UInt8, payload: Data)? {
        // Need at least 2 bytes for base header.
        guard buffer.count >= 2 else { return nil }

        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.startIndex + 1]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0

        guard fin else {
            // Fragmented frames are not supported in v1.
            buffer.removeAll()
            return nil
        }

        var offset = 2
        var payloadLen = Int(b1 & 0x7F)

        if payloadLen == 126 {
            guard buffer.count >= offset + 2 else { return nil }
            let high = Int(buffer[offset])
            let low = Int(buffer[offset + 1])
            payloadLen = (high << 8) | low
            offset += 2
        } else if payloadLen == 127 {
            guard buffer.count >= offset + 8 else { return nil }
            var len: UInt64 = 0
            for index in 0..<8 {
                len = (len << 8) | UInt64(buffer[offset + index])
            }
            guard len <= 2_000_000 else {
                buffer.removeAll()
                return nil
            }
            payloadLen = Int(len)
            offset += 8
        }

        var maskingKey: [UInt8] = [0, 0, 0, 0]
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            maskingKey = Array(buffer[offset..<(offset + 4)])
            offset += 4
        }

        guard buffer.count >= offset + payloadLen else { return nil }

        var payload = Data(buffer[offset..<(offset + payloadLen)])
        if masked {
            payload.withUnsafeMutableBytes { rawBuffer in
                guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for index in 0..<payloadLen {
                    bytes[index] ^= maskingKey[index % 4]
                }
            }
        }

        buffer.removeSubrange(0..<(offset + payloadLen))
        return (opcode: opcode, payload: payload)
    }
}
