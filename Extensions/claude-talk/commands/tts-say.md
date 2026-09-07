---
description: "Speak arbitrary text via Claude Talk"
argument-hint: "<text to speak>"
allowed-tools: ["Bash"]
---

Speak the provided text using Claude Talk:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tts-control.py" say $ARGUMENTS
```

Report the result briefly.
