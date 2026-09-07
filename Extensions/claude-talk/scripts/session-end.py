#!/usr/bin/env python3
"""
SessionEnd hook: Cleans up the inbox watcher background process.
"""

import json
import os
import sys

WATCHER_PID_FILE = "/tmp/loqui-inbox-watcher.pid"
INBOX_BASE_DIR = os.path.expanduser("~/.pi/agent/pitalk-inbox")
STATE_FILE = "/tmp/loqui-tts-state.json"


def main():
    # Kill the inbox watcher
    try:
        if os.path.exists(WATCHER_PID_FILE):
            with open(WATCHER_PID_FILE) as f:
                pid = int(f.read().strip())
            try:
                os.kill(pid, 15)  # SIGTERM
            except ProcessLookupError:
                pass
            os.unlink(WATCHER_PID_FILE)
    except Exception:
        pass

    # Clean up inbox directory
    try:
        state = {}
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE) as f:
                state = json.load(f)
        claude_pid = state.get("claude_pid")
        if claude_pid:
            inbox_dir = os.path.join(INBOX_BASE_DIR, str(claude_pid))
            if os.path.isdir(inbox_dir):
                import shutil
                shutil.rmtree(inbox_dir, ignore_errors=True)
    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
