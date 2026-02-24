import XCTest
@testable import PiTalk

final class PiTalkWebSocketTests: XCTestCase {
    func testHandshakeBuildUpgradeResponseSuccess() throws {
        let rawHeaders = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1:18082",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==",
            "\r\n",
        ].joined(separator: "\r\n")

        let result = PiTalkWebSocketHandshake.buildUpgradeResponse(from: rawHeaders)
        let response = try XCTUnwrap({
            if case .success(let value) = result { return value }
            return nil
        }())

        XCTAssertTrue(response.contains("HTTP/1.1 101 Switching Protocols"))
        XCTAssertTrue(response.contains("Sec-WebSocket-Accept: qGEgH3En71di5rrssAZTmtRTyFk="))
    }

    func testHandshakeRejectsMissingUpgradeHeader() {
        let rawHeaders = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1:18082",
            "Sec-WebSocket-Version: 13",
            "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==",
            "\r\n",
        ].joined(separator: "\r\n")

        let result = PiTalkWebSocketHandshake.buildUpgradeResponse(from: rawHeaders)
        XCTAssertEqual(result.errorValue, .upgradeRequired)
    }

    func testHandshakeRejectsMissingWebSocketKey() {
        let rawHeaders = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1:18082",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Version: 13",
            "\r\n",
        ].joined(separator: "\r\n")

        let result = PiTalkWebSocketHandshake.buildUpgradeResponse(from: rawHeaders)
        XCTAssertEqual(result.errorValue, .badRequest)
    }

    func testFrameRoundTripTextPayload() throws {
        let payload = Data("hello world".utf8)
        var buffer = PiTalkWebSocketCodec.encodeFrame(opcode: 0x1, payload: payload)

        let frame = try XCTUnwrap(PiTalkWebSocketCodec.readFrame(from: &buffer))
        XCTAssertEqual(frame.opcode, 0x1)
        XCTAssertEqual(frame.payload, payload)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testFrameDecodeMaskedClientPayload() throws {
        let payload = Data("masked frame".utf8)
        let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]

        var frame = Data()
        frame.append(0x81) // FIN + text
        frame.append(0x80 | UInt8(payload.count)) // masked + len
        frame.append(contentsOf: mask)

        for (index, byte) in payload.enumerated() {
            frame.append(byte ^ mask[index % 4])
        }

        var buffer = frame
        let decoded = try XCTUnwrap(PiTalkWebSocketCodec.readFrame(from: &buffer))
        XCTAssertEqual(decoded.opcode, 0x1)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testFrameDecodeRejectsOversizedPayload() {
        let payload = Data(repeating: 0x41, count: 300)
        var buffer = PiTalkWebSocketCodec.encodeFrame(opcode: 0x1, payload: payload)

        let frame = PiTalkWebSocketCodec.readFrame(from: &buffer, maxPayloadBytes: 100)
        XCTAssertNil(frame)
        XCTAssertTrue(buffer.isEmpty)
    }
}

private extension Result {
    var errorValue: Failure? {
        guard case .failure(let value) = self else { return nil }
        return value
    }
}
