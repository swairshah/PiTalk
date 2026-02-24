import XCTest
@testable import PiTalk

final class PiTalkRemoteWireTests: XCTestCase {
    func testFrameEncodeDecodeRoundTrip() throws {
        let frame = PiTalkRemoteFrame(
            type: .cmd,
            name: "session.sendText",
            requestId: "req-1",
            idempotencyKey: "idem-1",
            seq: nil,
            ts: 123,
            payload: .object([
                "sessionKey": .string("pi::main"),
                "text": .string("hello"),
            ])
        )

        let data = try XCTUnwrap(frame.encodeData())
        let decoded = try XCTUnwrap(PiTalkRemoteFrame.decodeData(data))

        XCTAssertEqual(decoded.type, .cmd)
        XCTAssertEqual(decoded.name, "session.sendText")
        XCTAssertEqual(decoded.requestId, "req-1")
        XCTAssertEqual(decoded.idempotencyKey, "idem-1")
    }

    func testCommandPayloadDecodeSessionSendText() {
        let payload: JSONValue = .object([
            "sessionKey": .string("pi::main"),
            "text": .string("Ship it"),
        ])

        let decoded = payload.decode(PiTalkRemoteSessionSendTextPayload.self)
        XCTAssertEqual(decoded?.sessionKey, "pi::main")
        XCTAssertEqual(decoded?.text, "Ship it")
    }

    func testCommandPayloadDecodeSpeak() {
        let payload: JSONValue = .object([
            "text": .string("hello from phone"),
            "voice": .string("auto"),
            "sourceApp": .string("pitalk-ios"),
            "sessionId": .string("iphone"),
            "pid": .integer(42),
        ])

        let decoded = payload.decode(PiTalkRemoteTTSSpeakPayload.self)
        XCTAssertEqual(decoded?.text, "hello from phone")
        XCTAssertEqual(decoded?.voice, "auto")
        XCTAssertEqual(decoded?.pid, 42)
    }

    func testJSONValueFromAnyDictionary() throws {
        let input: [String: Any] = [
            "ok": true,
            "count": 3,
            "nested": ["msg": "hi"],
        ]

        let value = try XCTUnwrap(JSONValue.from(any: input))
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["ok"], .bool(true))
        XCTAssertEqual(object["count"], .integer(3))
        XCTAssertEqual(object["nested"]?.objectValue?["msg"], .string("hi"))
    }

    func testErrorFramePayloadContainsCodeAndMessage() {
        let frame = PiTalkRemoteFrame.error(
            name: "auth.hello",
            requestId: "req-err",
            code: "AUTH_INVALID",
            message: "invalid token"
        )

        let payload = frame.payload?.objectValue
        XCTAssertEqual(payload?["code"], .string("AUTH_INVALID"))
        XCTAssertEqual(payload?["message"], .string("invalid token"))
    }
}
