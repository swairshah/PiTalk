# <img src="Resources/icons/app-icon.png" alt="PiTalk icon" width="34" align="center" /> PiTalk

PiTalk is a macOS menu bar app that acts as a local voice hub.

It’s great with Pi, but it’s not Pi-only any app can send text to PiTalk’s local broker and have it spoken through the same centralized queue + playback system.

## Install with Homebrew

```bash
brew tap swairshah/tap
brew install --cask pitalk
```

Then launch PiTalk from Applications (or via Spotlight) and start sending broker requests.

## What this app does

- Runs a local speech broker on `127.0.0.1:18081` (NDJSON over TCP)
- Accepts `speak`, `health`, and `stop` commands from any local client
- Queues and coordinates playback so multiple sources can share one voice pipeline
- Streams low-latency TTS audio
- Shows live status in the menu bar
- Supports instant stop (including global **Cmd+.**)
- Keeps request history (queued / playing / played / interrupted / failed)

## Use it as a voice hub (from any app)

Example broker call:

```bash
echo '{"type":"speak","text":"Hello from another app","sourceApp":"my-app","sessionId":"abc-123"}' | nc 127.0.0.1 18081
```

Health check:

```bash
echo '{"type":"health"}' | nc 127.0.0.1 18081
```

Stop all speech:

```bash
echo '{"type":"stop"}' | nc 127.0.0.1 18081
```

## Pi-specific pieces in this repo

- **`Extensions/pi-talk`** — extracts `<voice>` tags from Pi responses and sends them to PiTalk
- **`Sources/PiTalk`** — menu bar app + broker + playback coordinator
- **`Sources/ptts`** — CLI client for enqueueing/stopping speech
- **`Sources/PiTalkClient`** — shared client helpers

## Quick start (dev)

```bash
./run-dev.sh
```

## Build app bundle

```bash
./scripts/build-app.sh
open .build/PiTalk.app
```

## Requirements

- macOS 13+
- `ffplay` for playback (`brew install ffmpeg`)
- ElevenLabs API key (`ELEVEN_API_KEY` / `ELEVENLABS_API_KEY`, or set in app settings)

## Acknowledgements

- Huge thanks to the **pi-statusbar** creator — the menu bar status UX was a big inspiration.
- In our Pi workflow, we use both the **pi-statusbar extension** and this repo’s **pi-talk extension** together.
