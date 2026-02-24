# PiTalk iOS App

This app is an iPhone companion for the PiTalk macOS host over Tailscale/WebSocket.

It is intentionally isolated under `apps/pitalk-ios/` so it can be changed or removed without affecting the macOS app.

## Current features

- Connect to PiTalk remote server profiles (`ws://<host>:18082/ws`)
- Auth handshake + reconnect behavior
- Sessions list + session detail timeline
- Send text to the selected session
- Push-to-talk (record -> transcribe -> send text)
- Remote audio mirror toggle (foreground-aware)
- Live Activities for active sessions
- Send screenshot to selected session:
  - pick with **Photo**
  - stage as **Screenshot ready**
  - send only when you tap **Send**
  - timeline shows **📷 Screenshot sent** marker

## Screenshot relay behavior

`session.sendScreenshot` stores the image on the Mac host and injects a text message into the selected Pi session with the saved file path.

Current host storage path format:

- `~/.pi/agent/pitalk-inbox-media/<pid>/<timestamp>-<uuid>.jpg`

## Docs

- Setup and run: `apps/pitalk-ios/SETUP.md`
- Protocol: `docs/REMOTE_WS_PROTOCOL.md`
- Planning notes: `docs/IOS_REMOTE_PLAN.md`

## iOS TODO

- [x] WebSocket connection + auth handshake
- [x] Session snapshot UI + detail timeline
- [x] `session.sendText` command path
- [x] Push-to-talk text send path
- [x] Remote audio streaming toggle
- [x] Screenshot send flow (stage then explicit send)
- [ ] Add explicit send progress state/toast for screenshot uploads
- [ ] Add iOS-side integration test harness for command routing (`session.sendText`, `session.sendScreenshot`, `tts.speak`, `tts.stop`)
- [ ] Add protocol conformance tests from iOS client perspective (idempotency retries, replay/resume, heartbeat timeout/reconnect)
