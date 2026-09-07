---
description: "Stop current Claude Talk speech"
allowed-tools: ["Bash"]
---

Stop any currently playing speech by running this command:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/tts-control.py" stop
```

Report the result to the user briefly.
