# ClaudeTalk

ClaudeTalk connects Claude Code to the PiTalk macOS app. Claude can speak summaries, explanations, and questions while you work.

## Install from this repository

From the PiTalk repository root, run:

```bash
./scripts/setup-claude-talk.sh install
./run-dev.sh
```

Restart Claude Code after installation. Run `/claude-talk:tts-status` to check the broker connection.

The setup script registers this checkout as a local Claude Code marketplace and installs `claude-talk@claudetalk` for the current user. The plugin connects to `127.0.0.1:18080` and `127.0.0.1:18081`, so it works with either the development app or a Homebrew installation.

To remove ClaudeTalk without removing PiTalk, run:

```bash
./scripts/setup-claude-talk.sh uninstall
```

## Install from GitHub

You can also install the plugin from Claude Code:

```text
/plugin marketplace add swairshah/PiTalk
/plugin install claude-talk@claudetalk
```

Restart Claude Code after installation.

## Commands

| Command | Description |
|---------|-------------|
| `/claude-talk:tts` | Turn TTS on or off |
| `/claude-talk:tts-stop` | Stop the current speech |
| `/claude-talk:tts-say <text>` | Speak arbitrary text |
| `/claude-talk:tts-voice [name]` | Show or change the voice |
| `/claude-talk:tts-style [mode]` | Use `succinct`, `verbose`, or `chatty` output |
| `/claude-talk:tts-status` | Check the plugin and broker status |

Available voices are `auto`, `alba`, `marius`, `javert`, `fantine`, `cosette`, `eponine`, and `azelma`.

Press **Cmd+.** to stop speech from any macOS app.

## How it works

ClaudeTalk adds instructions that ask Claude to wrap spoken text in `<voice>` tags. Its hooks extract complete voice sections and send them to the local PiTalk broker as NDJSON over TCP. PiTalk keeps a separate queue for each Claude Code session.

PiTalk must be running for playback. The plugin does not require the Pi extension or `pi-telemetry`.

## License

MIT
