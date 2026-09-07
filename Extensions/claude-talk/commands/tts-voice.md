---
description: "Change Claude Talk voice (auto, alba, marius, javert, fantine, cosette, eponine, azelma)"
argument-hint: "[voice-name]"
allowed-tools: ["Bash"]
---

Change or show the current TTS voice:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tts-control.py" voice $ARGUMENTS
```

Show the result to the user.
