---
description: "Set or cycle the TTS verbosity style (succinct/verbose/chatty)"
allowed-tools: ["Bash"]
---

Cycle through styles, or set a specific one. The argument $ARGUMENTS may be empty (cycle), or one of: succinct, verbose, chatty.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tts-control.py" style $ARGUMENTS
```

Report the result. Tell the user the new style takes effect on the next message.
