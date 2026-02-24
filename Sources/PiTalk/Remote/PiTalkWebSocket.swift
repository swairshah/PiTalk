import CryptoKit
import Foundation

enum PiTalkWebSocketHandshakeError: String, Error {
    case badRequest = "400 Bad Request"
    case upgradeRequired = "426 Upgrade Required"
}

enum PiTalkWebSocketHandshake {
    private static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func buildUpgradeResponse(from rawHeaders: String) -> Result<String, PiTalkWebSocketHandshakeError> {
        let lines = rawHeaders.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let requestLine = lines.first, requestLine.lowercased().hasPrefix("get ") else {
            return .failure(.badRequest)
        }

        var headerMap: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<split]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headerMap[key] = value
        }

        guard let upgrade = headerMap["upgrade"], upgrade.lowercased() == "websocket" else {
            return .failure(.upgradeRequired)
        }

        guard let wsKey = headerMap["sec-websocket-key"], !wsKey.isEmpty else {
            return .failure(.badRequest)
        }

        let accept = websocketAccept(for: wsKey)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "\r\n",
        ].joined(separator: "\r\n")
        return .success(response)
    }

    static func websocketAccept(for key: String) -> String {
        let concatenated = key + acceptGUID
        let digest = Insecure.SHA1.hash(data: Data(concatenated.utf8))
        return Data(digest).base64EncodedString()
    }
}

struct PiTalkWebSocketFrame {
    let opcode: UInt8
    let payload: Data
}

enum PiTalkWebSocketCodec {
    static func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | opcode) // FIN + opcode

        let payloadLength = payload.count
        if payloadLength < 126 {
            frame.append(UInt8(payloadLength))
        } else if payloadLength <= 0xFFFF {
            frame.append(126)
            let high = UInt8((payloadLength >> 8) & 0xFF)
            let low = UInt8(payloadLength & 0xFF)
            frame.append(high)
            frame.append(low)
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payloadLength) >> UInt64(shift)) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }

    static func readFrame(from buffer: inout Data, maxPayloadBytes: Int = 2_000_000) -> PiTalkWebSocketFrame? {
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
            guard len <= UInt64(maxPayloadBytes) else {
                buffer.removeAll()
                return nil
            }
            payloadLen = Int(len)
            offset += 8
        }

        guard payloadLen <= maxPayloadBytes else {
            buffer.removeAll()
            return nil
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
        return PiTalkWebSocketFrame(opcode: opcode, payload: payload)
    }
}
