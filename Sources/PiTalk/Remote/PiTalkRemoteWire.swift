import Foundation

enum PiTalkRemoteFrameType: String, Codable {
    case cmd
    case ack
    case event
    case error
    case ping
    case pong
}

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }
        if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
            return
        }
        if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
            return
        }
        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let intValue = try? container.decode(Int64.self) {
            self = .integer(intValue)
            return
        }
        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let object):
            try container.encode(object)
        case .array(let array):
            try container.encode(array)
        case .string(let string):
            try container.encode(string)
        case .integer(let intValue):
            try container.encode(intValue)
        case .double(let doubleValue):
            try container.encode(doubleValue)
        case .bool(let boolValue):
            try container.encode(boolValue)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var int64Value: Int64? {
        switch self {
        case .integer(let value):
            return value
        case .double(let value):
            return Int64(value)
        case .string(let value):
            return Int64(value)
        default:
            return nil
        }
    }

    static func fromEncodable<T: Encodable>(_ value: T) -> JSONValue? {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            return nil
        }
    }

    static func from(any value: Any) -> JSONValue? {
        switch value {
        case let value as JSONValue:
            return value
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .integer(Int64(value))
        case let value as Int8:
            return .integer(Int64(value))
        case let value as Int16:
            return .integer(Int64(value))
        case let value as Int32:
            return .integer(Int64(value))
        case let value as Int64:
            return .integer(value)
        case let value as UInt:
            return .integer(Int64(value))
        case let value as UInt8:
            return .integer(Int64(value))
        case let value as UInt16:
            return .integer(Int64(value))
        case let value as UInt32:
            return .integer(Int64(value))
        case let value as UInt64:
            if value <= UInt64(Int64.max) {
                return .integer(Int64(value))
            }
            return .double(Double(value))
        case let value as Double:
            return .double(value)
        case let value as Float:
            return .double(Double(value))
        case is NSNull:
            return .null
        case let value as [Any]:
            let converted = value.compactMap { from(any: $0) }
            guard converted.count == value.count else { return nil }
            return .array(converted)
        case let value as [String: Any]:
            var converted: [String: JSONValue] = [:]
            for (key, item) in value {
                guard let convertedItem = from(any: item) else { return nil }
                converted[key] = convertedItem
            }
            return .object(converted)
        default:
            return nil
        }
    }

    func decode<T: Decodable>(_ type: T.Type) -> T? {
        do {
            let data = try JSONEncoder().encode(self)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }
}

struct PiTalkRemoteFrame: Codable {
    let type: PiTalkRemoteFrameType
    let name: String?
    let requestId: String?
    let idempotencyKey: String?
    let seq: Int64?
    let ts: Int64?
    let payload: JSONValue?

    static func event(name: String, seq: Int64, payload: JSONValue?) -> PiTalkRemoteFrame {
        PiTalkRemoteFrame(
            type: .event,
            name: name,
            requestId: nil,
            idempotencyKey: nil,
            seq: seq,
            ts: pitalkRemoteCurrentTimestampMs(),
            payload: payload
        )
    }

    static func ack(name: String, requestId: String, payload: JSONValue?) -> PiTalkRemoteFrame {
        PiTalkRemoteFrame(
            type: .ack,
            name: name,
            requestId: requestId,
            idempotencyKey: nil,
            seq: nil,
            ts: pitalkRemoteCurrentTimestampMs(),
            payload: payload
        )
    }

    static func error(name: String, requestId: String, code: String, message: String) -> PiTalkRemoteFrame {
        PiTalkRemoteFrame(
            type: .error,
            name: name,
            requestId: requestId,
            idempotencyKey: nil,
            seq: nil,
            ts: pitalkRemoteCurrentTimestampMs(),
            payload: .object([
                "code": .string(code),
                "message": .string(message),
            ])
        )
    }

    static func protocolError(code: String, message: String) -> PiTalkRemoteFrame {
        PiTalkRemoteFrame.error(name: "protocol", requestId: UUID().uuidString, code: code, message: message)
    }

    func encodeData() -> Data? {
        let encoder = JSONEncoder()
        return try? encoder.encode(self)
    }

    static func decodeData(_ data: Data) -> PiTalkRemoteFrame? {
        let decoder = JSONDecoder()
        return try? decoder.decode(PiTalkRemoteFrame.self, from: data)
    }
}

struct PiTalkRemoteAuthHelloPayload: Codable {
    let token: String?
    let clientName: String?
    let clientVersion: String?
    let resumeFromSeq: Int64?
}

struct PiTalkRemoteSessionSendTextPayload: Codable {
    let sessionKey: String
    let text: String
}

struct PiTalkRemoteTTSSpeakPayload: Codable {
    let text: String
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int?
}

struct PiTalkRemoteTTSStopPayload: Codable {
    let scope: String?
}

struct PiTalkRemoteServerHelloPayload: Codable {
    struct ServerInfo: Codable {
        let name: String
        let version: String
    }

    let server: ServerInfo
    let requiresAuth: Bool
    let eventSeq: Int64
}

struct PiTalkRemoteAuthAckPayload: Codable {
    struct Replay: Codable {
        let requestedFromSeq: Int64?
    }

    let serverVersion: String
    let sessionId: String
    let eventSeq: Int64
    let replay: Replay
}
