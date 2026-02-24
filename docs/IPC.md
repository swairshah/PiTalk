# Loqui IPC Design (Broker)

Loqui exposes a local broker endpoint for centralized queueing and playback:

- Address: `127.0.0.1:18081`
- Protocol: NDJSON over TCP (one JSON object per line)

For remote iOS/WebSocket control, see `docs/REMOTE_WS_PROTOCOL.md`.

## Commands

### speak

```json
{"type":"speak","text":"Hello","voice":"fantine","sourceApp":"pi","sessionId":"abc","pid":12345}
```

Fields:
- `text` (required)
- `voice` (optional)
- `sourceApp` (optional)
- `sessionId` (optional)
- `pid` (optional)

### health

```json
{"type":"health"}
```

### stop

```json
{"type":"stop"}
```

## Response shape

Responses are JSON lines and can include:
- `ok`
- `queued`
- `pending`
- `playing`
- `currentQueue`
- `error`

## Queue model

Queue key is:

`sourceApp + sessionId`

Rules:
- Missing session IDs are normalized to a shared `none` session.
- Each queue key has its own FIFO queue.
- Scheduler drains the current queue key before moving to the next queue key.

## Voice assignment behavior

If `voice` is omitted in `speak`:
- Loqui assigns a stable per-queue default from:
  - `fantine`, `cosette`, `marius`, `azelma`
- Loqui tries to keep active queues on distinct voices.
- If active queues exceed 4, assignment cycles.

If `voice` is provided, it is used directly.

## Microphone-aware behavior

When microphone activity is detected:
- If Loqui is already speaking: current item is interrupted and queued items are cancelled.
- If Loqui is not speaking yet: queued playback waits until microphone activity ends.

Detection is done via CoreAudio device-running state for the default input device (no audio capture by Loqui).
