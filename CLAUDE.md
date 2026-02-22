# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PiTalk is a macOS menu bar application that provides centralized text-to-speech queuing and playback via a TCP broker. It streams audio from the ElevenLabs API and plays it via `ffplay`. Designed for the Pi coding agent but usable by any local app.

## Build & Run Commands

```bash
swift build                          # Debug build
swift build -c release               # Release build
./run-dev.sh                         # Debug build + launch with PITALK_DEBUG=1
./run.sh                             # Build + launch via open, with health checks
./scripts/build-app.sh               # Release build + create .app bundle
./scripts/build-app.sh --universal   # Universal binary (arm64 + x86_64)
./scripts/release.sh <version>       # Full release: build, notarize, staple, homebrew
```

There are no tests or linter configured.

## Architecture

**Swift Package Manager** (swift-tools-version: 5.9, macOS 13+). Three targets, zero external Swift dependencies:
- `PiTalk` — main menu bar app (SwiftUI MenuBarExtra)
- `PiTalkClient` — shared HTTP client library for TTS server
- `ptts` — CLI tool (depends on PiTalkClient)

### Core Components (all in `PiTalkApp.swift` ~2600 lines)

- **PiTalkApp** (`@main`) — SwiftUI app entry point with MenuBarExtra
- **AppDelegate** — Sets up global Cmd+. hotkey (Carbon), owns the coordinator, broker, mic monitor, health server. Singleton via `AppDelegate.shared`
- **LocalSpeechBroker** — TCP server on port 18081 (NWListener). Accepts NDJSON commands: `speak`, `health`, `stop`
- **SpeechPlaybackCoordinator** — Central playback engine. Per-source queue buckets keyed by `sourceApp::sessionId`. Round-robin scheduling, auto voice assignment from pool. Streams ElevenLabs audio to temp MP3, plays via `ffplay`. Uses serial DispatchQueue for thread safety and UUID nonces for stale job detection
- **HealthHTTPServer** — HTTP server on port 18080, returns `{"ok":true}` at `/health`
- **MicrophoneActivityMonitor** — Polls CoreAudio input device state; interrupts speech when mic is active
- **RequestHistoryStore** — Singleton, persists to `~/Library/Application Support/PiTalk/request-history.json` (max 250 entries)
- All SwiftUI views (Settings, Sessions, History, About) are also in this file

### Supporting Files

- **VoiceMonitor** (`VoiceMonitor.swift`) — `@MainActor ObservableObject`, 1-second polling timer, reads Pi telemetry from `~/.pi/agent/telemetry/instances/*.json`, drives the UI
- **DaemonClient** (`DaemonClient.swift`) — Unix socket client for `pi-statusd` at `~/.pi/agent/statusd.sock`. Commands: `status`, `jump <pid>`, `send <pid> <text>`
- **JumpHandler** (`JumpHandler.swift`) — Focuses terminal windows for a PID. Supports Ghostty (CGWindowList + Accessibility API), iTerm2/Terminal (AppleScript), tmux/zellij detection
- **SendHandler** (`SendHandler.swift`) — Sends text to terminal sessions via tmux `send-keys`, zellij `write-chars`, or Ghostty keystrokes
- **TTSClient** (`PiTalkClient/TTSClient.swift`) — HTTP client for TTS server (legacy local TTS voice names, not the current ElevenLabs voices)

### Pi Extension (`Extensions/pi-talk/`)

TypeScript npm package (`@swairshah/pi-talk`) for the Pi coding agent. Extracts `<voice>` tags from streaming responses and sends speech to the broker on port 18081.

## Key Patterns

- Debug logging gated by `PITALK_DEBUG=1` env var (duplicated `fileprivate let debugEnabled` in multiple files)
- UserDefaults for settings (voice, API key, server enabled stored inverted as "serverDisabled", speech speed, dock icon, launch at login)
- `LSUIElement=true` — menu bar app, dock icon is toggleable
- App bundle ID: `com.pitalk.app`
- ElevenLabs voices: `ally` (default), `dorothy`, `lily`, `alice`, `dave`, `joseph` using `eleven_flash_v2_5` model
- Requires `ffplay` (ffmpeg) for audio playback and Accessibility permissions for terminal focusing

## Network Ports

| Port  | Protocol   | Purpose                        |
|-------|------------|--------------------------------|
| 18080 | HTTP       | Health check server            |
| 18081 | TCP/NDJSON | Speech broker (speak/stop/health) |

## IPC Protocol

Broker protocol documented in `docs/IPC.md`. NDJSON over TCP on port 18081.
