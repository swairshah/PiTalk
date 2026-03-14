# pi-talk

Text-to-speech extension for [Pi coding agent](https://github.com/mariozechner/pi-coding-agent). Gives Pi a voice using `<voice>` tags.

![pi-talk demo](https://raw.githubusercontent.com/swairshah/Loqui/main/assets/demo.gif)

## Features

- **Local TTS** - No cloud APIs, runs entirely on your Mac
- **Multiple voices** - 7 different voice options
- **Central playback** - Pi sends speech jobs to Loqui's local broker queue
- **Configurable** - Toggle verbosity, mute, change voices

## Requirements

**Loqui.app** must be installed and running (provides the TTS server + local broker queue).

```bash
brew install swairshah/tap/loqui
```

Then launch Loqui from Applications - it runs in the menubar.

## Installation

```bash
pi install npm:@swairshah/pi-talk
```

## Usage

Once installed, Pi will automatically speak `<voice>` tagged content in its responses.

### Commands

| Command | Description |
|---------|-------------|
| `/tts` | Toggle TTS on/off |
| `/tts-mute` | Mute audio (keeps voice tags in responses) |
| `/tts-voice <name>` | Change voice (alba, marius, javert, fantine, cosette, eponine, azelma) |
| `/tts-style` | Toggle between succinct and verbose voice prompts |
| `/tts-say <text>` | Speak arbitrary text |
| `/tts-stop` | Stop current speech |
| `/tts-status` | Show current status |

### Global Shortcut

Press **Cmd+.** to stop speech at any time (requires Loqui.app running).

## How it works

1. The extension injects a system prompt that teaches Pi to use `<voice>` tags
2. When Pi responds, the extension extracts `<voice>` content
3. The extension sends speech jobs to Loqui's local broker (`127.0.0.1:18081`), including `sourceApp`, `sessionId`, and `pid`
4. Loqui schedules per-session queues and plays audio centrally (no cloud, no API keys)

## Publishing (maintainers)

From repo root:

```bash
./scripts/publish-pi-talk.sh --dry-run
./scripts/publish-pi-talk.sh --bump patch
```

Or from this directory:

```bash
npm run pack:preview
npm run publish:npm
```

## Credits

- TTS model: [Pocket TTS](https://github.com/kyutai-labs/moshi) by Kyutai Labs
- Rust implementation: [pocket-tts](https://github.com/babybirdprd/pocket-tts) by babybirdprd

## License

MIT
