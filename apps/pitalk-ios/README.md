# PiTalk iOS App (Scaffold)

This folder is intentionally isolated so it can be removed without affecting core PiTalk.

## Scope

Companion app for PiTalk macOS host over Tailscale:

- View active sessions
- View live status/events
- Send text to a selected session
- Push-to-talk (record -> transcribe -> send text)

## Proposed Structure

```
apps/pitalk-ios/
  PiTalkiOS.xcodeproj
  PiTalkiOS/
    App/
    Features/
      Sessions/
      SessionDetail/
      History/
      Settings/
    Networking/
      RemoteSocketClient.swift
      ProtocolModels.swift
      ReconnectPolicy.swift
    Audio/
      Recorder.swift
      SpeechTranscriber.swift
    Storage/
      KeychainStore.swift
      LastEventStore.swift
```

## State Model

Use a single source of truth store for:

- connection state
- sessions snapshot
- playback state
- history list
- last seen event sequence

## MVP Checklist

- [ ] Connect to remote PiTalk WebSocket endpoint.
- [ ] Token auth handshake.
- [ ] Sessions list UI with status chips.
- [ ] Session detail with send text action.
- [ ] Stop all action.
- [ ] Reconnect + resume-from-seq support.
- [ ] Push-to-talk text send path.

## Notes

Protocol details live in `docs/REMOTE_WS_PROTOCOL.md`.
