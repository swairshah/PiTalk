# PiTalk iOS Remote App Plan

Branch: `feature/pitalk-ios-remote`

## Goal

Build a removable iPhone companion app that can:

1. Discover/connect to a PiTalk host on Tailscale.
2. Show active Pi sessions (similar to menu bar session visibility).
3. Show live playback/session state updates.
4. Send text (and later push-to-talk audio) back to a selected Pi session.

## Non-goals (v1)

- No terminal jump/focus functionality.
- No dependency on OpenClaw gateway.
- No cloud relay service.

## Isolation / Repo Layout

Keep iOS work in a separate folder so it can be removed cleanly.

- `apps/pitalk-ios/` — iOS app only
- `Sources/PiTalk/Remote/` — macOS-hosted remote transport layer only
- `docs/REMOTE_WS_PROTOCOL.md` — protocol spec shared by both sides

Minimal touch points in existing code:

- `AppDelegate` starts/stops `PiTalkRemoteServer`.
- Existing `VoiceMonitor`/history/coordinator publish state to remote server adapter.
- Existing send-to-session logic is reused from inbox writer behavior.

## UX Shape (iOS)

### 1) Sessions Screen (default)

- Header health pill: Connected / Reconnecting / Offline
- Session list rows:
  - source app
  - short session id
  - status chip (speaking/queued/running/waiting/idle)
  - queued count
  - last snippet + relative time
- Actions:
  - tap row => Session Detail
  - top-level Stop All

### 2) Session Detail

- Live transcript/event timeline (delta/final markers)
- Text input + send
- Hold-to-talk button:
  - press = record
  - release = transcribe + send text to selected session
- Stop speech button (session/global behavior decided by command mode)

### 3) History Screen

- Recently queued/played/interrupted/failed entries
- Filter by session

### 4) Settings Screen

- Host (tailnet DNS/IP + port)
- Token pairing
- Reconnect/backoff diagnostics
- Optional: event log export for debugging

## Milestones

## M0 — Protocol + scaffolding

- [x] Create `docs/REMOTE_WS_PROTOCOL.md` with command/event schemas.
- [x] Add `Sources/PiTalk/Remote/` module scaffold.
- [x] Add `apps/pitalk-ios/` scaffold + architecture notes.

## M1 — macOS server baseline

- [x] `PiTalkRemoteServer` WebSocket listener (default `127.0.0.1:18082` + optional tailnet bind).
- [x] Token auth handshake (`auth.hello`).
- [x] `sessions.snapshot.get` command.
- [x] Heartbeat ping/pong.

Definition of done: iOS client can connect and fetch current snapshot.

## M2 — Live event streaming

- [x] Publish `sessions.updated` events when session state changes.
- [x] Publish `playback.state` and `history.appended` events.
- [x] Add global monotonically increasing `seq` for all emitted events.

Definition of done: iOS list updates in near-real-time without manual refresh.

## M3 — Send actions

- [x] `session.sendText` command routed to Pi inbox for target session.
- [x] `tts.speak` + `tts.stop` command support.
- [x] Idempotency key support for command retries.

Definition of done: iOS can talk back to selected session reliably.

## M4 — Push-to-talk

- [x] iOS press-and-hold capture.
- [x] Local STT first (server STT fallback left for later).
- [x] Send transcript via `session.sendText`.

Definition of done: voice roundtrip from phone into a chosen session.

## M5 — Resilience hardening

- [x] Reconnect with exponential backoff.
- [x] `resumeFromSeq` reconnect support.
- [x] Snapshot fallback when replay window unavailable.
- [ ] Background/foreground lifecycle handling.

Definition of done: recover cleanly after drops without state drift.

## Reliability Rules

- Every command has `requestId` + `idempotencyKey`.
- Server replies with explicit ack/error for every command.
- Server events include strictly increasing `seq`.
- Client reconnects with `resumeFromSeq`.
- If replay cannot be satisfied, server sends full snapshot and reset marker.

## Security

- Require shared token auth for any non-loopback bind.
- Default bind stays loopback unless explicitly enabled for remote.
- Keep token in iOS Keychain.
- Add optional allowlist for specific tailnet source IPs (later phase).

## Open Decisions

- Whether `tts.stop` is global or scoped by session.
- Whether iOS PTT uploads raw audio (future) versus STT text only (v1 text only).
- Whether TLS is needed over tailnet for v1 (likely optional if token auth + tailnet only).
