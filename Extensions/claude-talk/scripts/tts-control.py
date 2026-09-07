#!/usr/bin/env python3
"""
Utility script for TTS control actions (stop, status, say, toggle).
Called by slash command hooks or directly.

Usage:
  tts-control.py stop          - Stop current speech
  tts-control.py status        - Show TTS status
  tts-control.py say <text>    - Speak arbitrary text
  tts-control.py toggle        - Toggle TTS on/off
  tts-control.py voice <name>  - Change voice
  tts-control.py style [name]  - Cycle/set verbosity (succinct|verbose|chatty)
"""

import json
import os
import socket
import sys
import urllib.request

TTS_HOST = "127.0.0.1"
TTS_PORT = 18080
BROKER_PORT = 18081
STATE_FILE = "/tmp/loqui-tts-state.json"
AVAILABLE_VOICES = ["auto", "alba", "marius", "javert", "fantine", "cosette", "eponine", "azelma"]
AVAILABLE_STYLES = ["succinct", "verbose", "chatty"]


def load_state():
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"enabled": True, "voice": "auto"}


def save_state(state):
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception:
        pass


def send_broker_command(command):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((TTS_HOST, BROKER_PORT))
        sock.sendall(json.dumps(command).encode() + b"\n")
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(1024)
            if not chunk:
                break
            data += chunk
        sock.close()
        return json.loads(data.decode().strip())
    except Exception as e:
        return {"ok": False, "error": str(e)}


def check_health():
    try:
        req = urllib.request.Request(f"http://{TTS_HOST}:{TTS_PORT}/health", method="GET")
        with urllib.request.urlopen(req, timeout=2) as resp:
            if resp.status != 200:
                return False
    except Exception:
        return False

    result = send_broker_command({"type": "health"})
    return result.get("ok", False)


def main():
    if len(sys.argv) < 2:
        print("Usage: tts-control.py <stop|status|say|toggle|voice|style> [args]")
        sys.exit(1)

    action = sys.argv[1]
    state = load_state()

    if action == "stop":
        result = send_broker_command({"type": "stop"})
        if result.get("ok"):
            print("Speech stopped.")
        else:
            print(f"Could not stop speech: {result.get('error', 'unknown')}")

    elif action == "status":
        healthy = check_health()
        voice = state.get("voice", "auto")
        style = state.get("style", "verbose")
        enabled = state.get("enabled", True)
        session_id = state.get("session_id", "unknown")
        print(f"Server: {'running ✓' if healthy else 'not running ✗'}")
        print(f"TTS: {'enabled' if enabled else 'disabled'}")
        print(f"Voice: {voice}")
        print(f"Style: {style}")
        print(f"Session: {session_id}")

    elif action == "say":
        text = " ".join(sys.argv[2:])
        if not text:
            print("Usage: tts-control.py say <text>")
            sys.exit(1)
        session_id = state.get("session_id", "unknown")
        voice = state.get("voice", "auto")
        result = send_broker_command({
            "type": "speak",
            "text": text,
            "sourceApp": "claude-code",
            "sessionId": session_id,
            **({"voice": voice} if voice != "auto" else {}),
        })
        if result.get("ok"):
            print(f"Speaking: {text[:60]}...")
        else:
            print(f"Failed: {result.get('error', 'unknown')}")

    elif action == "toggle":
        state["enabled"] = not state.get("enabled", True)
        save_state(state)
        status = "enabled" if state["enabled"] else "disabled"
        print(f"TTS {status}. Restart session for voice prompt changes to take effect.")

    elif action == "voice":
        if len(sys.argv) < 3:
            current = state.get("voice", "auto")
            print(f"Current voice: {current}")
            print(f"Available: {', '.join(AVAILABLE_VOICES)}")
            sys.exit(0)
        voice = sys.argv[2].lower()
        if voice not in AVAILABLE_VOICES:
            print(f"Unknown voice: {voice}")
            print(f"Available: {', '.join(AVAILABLE_VOICES)}")
            sys.exit(1)
        state["voice"] = voice
        save_state(state)
        print(f"Voice changed to: {voice}")

    elif action == "style":
        if len(sys.argv) < 3:
            # No arg: cycle to the next style in the list
            current = state.get("style", "verbose")
            try:
                next_idx = (AVAILABLE_STYLES.index(current) + 1) % len(AVAILABLE_STYLES)
            except ValueError:
                next_idx = 0
            new_style = AVAILABLE_STYLES[next_idx]
        else:
            new_style = sys.argv[2].lower()
            if new_style not in AVAILABLE_STYLES:
                print(f"Unknown style: {new_style}")
                print(f"Available: {', '.join(AVAILABLE_STYLES)}")
                sys.exit(1)
        state["style"] = new_style
        save_state(state)
        print(f"Style changed to: {new_style}. Takes effect on your next message.")

    else:
        print(f"Unknown action: {action}")
        sys.exit(1)


if __name__ == "__main__":
    main()
