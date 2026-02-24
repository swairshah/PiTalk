# PiTalk Remote WebSocket Protocol (Draft v1)

This protocol is for PiTalk iOS <-> PiTalk macOS direct communication over Tailscale.

- Transport: WebSocket
- Suggested endpoint: `ws://<host>:18082/ws`
- Auth: shared token via handshake command
- Encoding: JSON frames

## Envelope

All frames use:

```json
{
  "type": "cmd|ack|event|error|ping|pong",
  "name": "auth.hello",
  "requestId": "uuid-or-short-id",
  "idempotencyKey": "optional-idempotency-key",
  "seq": 123,
  "ts": 1730000000000,
  "payload": {}
}
```

Notes:

- `requestId` required for `cmd`; echoed in `ack`/`error`.
- `seq` is present on replayable state events (`sessions.updated`, `playback.state`, `history.appended`, `stream.reset`).
- `idempotencyKey` required for mutating commands.

## Handshake

### Client -> Server

`auth.hello`

```json
{
  "type": "cmd",
  "name": "auth.hello",
  "requestId": "r1",
  "payload": {
    "token": "<shared-token>",
    "clientName": "pitalk-ios",
    "clientVersion": "0.1.0",
    "resumeFromSeq": 120
  }
}
```

### Server -> Client (success)

```json
{
  "type": "ack",
  "name": "auth.hello",
  "requestId": "r1",
  "payload": {
    "serverVersion": "0.1.0",
    "sessionId": "conn-123",
    "eventSeq": 150,
    "replay": {
      "applied": true,
      "fromSeq": 121,
      "toSeq": 150
    }
  }
}
```

### Server -> Client (failure)

```json
{
  "type": "error",
  "name": "auth.hello",
  "requestId": "r1",
  "payload": {
    "code": "AUTH_INVALID",
    "message": "invalid token"
  }
}
```

## Commands

## `sessions.snapshot.get`

Returns current active sessions + summary + playback state.

## `session.sendText`

Payload:

```json
{
  "sessionKey": "pi::session-abc",
  "text": "Hey Pi, summarize this",
  "idempotencyKey": "idem-123"
}
```

Behavior:

- Writes into target Pi inbox path for mapped PID/session.
- Returns ack with delivery result.

## `session.sendScreenshot`

Payload:

```json
{
  "sessionKey": "pi::session-abc",
  "imageBase64": "<base64-jpeg-or-png>",
  "mimeType": "image/jpeg",
  "note": "Optional user note",
  "idempotencyKey": "idem-456"
}
```

Behavior:

- Server stores the screenshot to a local file under `~/.pi/agent/pitalk-inbox-media/<pid>/...`.
- Server sends a text message into the target Pi session that includes the saved image path, so the agent can inspect the image.
- Returns ack with `imagePath` when delivered.

## `tts.speak`

Payload:

```json
{
  "text": "hello from iphone",
  "voice": "auto",
  "sourceApp": "pitalk-ios",
  "sessionId": "phone"
}
```

## `tts.stop`

Payload:

```json
{
  "scope": "global"
}
```

(v1 global stop; session-scoped stop can be added later)

## `audio.setStream`

Controls remote audio chunk fan-out for this websocket client.

Payload:

```json
{
  "enabled": true
}
```

Behavior:

- Default is `enabled=false` on every new connection.
- When `enabled=false`, the server does **not** send audio chunks to that client.
- When toggled back to `enabled=true`, streaming resumes from the **next live chunk** (no backlog replay).

## Events

## `sessions.updated`

Emitted when session list or status changes.

Payload:

```json
{
  "summary": {
    "total": 3,
    "speaking": 1,
    "queued": 1,
    "idle": 1,
    "label": "1 speaking"
  },
  "sessions": []
}
```

## `playback.state`

Emitted when queue/playing state changes.

## `history.appended`

Emitted when a new history entry is recorded.

## `audio.start` / `audio.chunk` / `audio.end`

Live audio mirror events for clients that enabled `audio.setStream`.

`audio.start` payload:

```json
{
  "streamId": "...",
  "sourceApp": "pi",
  "sessionId": "...",
  "pid": 12345,
  "voice": "ally",
  "mimeType": "audio/mpeg"
}
```

`audio.chunk` payload:

```json
{
  "streamId": "...",
  "chunk": "<base64-mp3-bytes>"
}
```

`audio.end` payload:

```json
{
  "streamId": "...",
  "status": "completed|interrupted|failed"
}
```

## `chat.delta` / `chat.final` (optional in v1)

Session stream updates for detail timeline.

## Sequencing and Replay

- Server maintains global event `seq`.
- Client stores last seen `seq`.
- On reconnect client sends `resumeFromSeq`.
- If replay available: emit missed events.
- If replay unavailable: send reset ack + full snapshot.

Reset marker example:

```json
{
  "type": "event",
  "name": "stream.reset",
  "seq": 200,
  "payload": {
    "reason": "replay-window-exceeded"
  }
}
```

## Heartbeats

- Server sends `ping` every 20s.
- Client replies `pong` within 10s.
- Missing 2 heartbeats => connection closed.

## Error Codes

- `AUTH_INVALID`
- `AUTH_REQUIRED`
- `BAD_REQUEST`
- `UNKNOWN_COMMAND`
- `SESSION_NOT_FOUND`
- `RATE_LIMITED`
- `INTERNAL_ERROR`

## Backwards Compatibility

Add optional `protocolVersion` in `auth.hello` payload once a v2 protocol exists.
