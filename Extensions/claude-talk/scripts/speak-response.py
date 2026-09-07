#!/usr/bin/env python3
"""
Stop hook: Reads the transcript, extracts <voice> tags from the last assistant
message, and sends them to the PiTalk broker for TTS playback.
"""

import json
import os
import re
import socket
import sys
import time
from datetime import datetime

TTS_HOST = "127.0.0.1"
BROKER_PORT = 18081
STATE_FILE = "/tmp/loqui-tts-state.json"
DEBUG_LOG = "/tmp/loqui-tts-debug.log"

# Per-message dedup. Shared with flush-voice.py (PreToolUse hook) so we don't
# re-speak chunks that already played mid-turn. Format: {msg_uuid: chunks_spoken}.
FLUSH_FILE = "/tmp/loqui-tts-flushed.json"


def debug(msg):
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}] {msg}\n")
    except:
        pass


def derive_session_id(input_data):
    """Display-friendly, per-session sessionId: "<cwd-basename>-<uuid[:8]>".

    Must stay identical to the derivation in style-reminder.py and
    flush-voice.py so drains line up with enqueues.
    """
    raw = input_data.get("session_id", "") or ""
    cwd = input_data.get("cwd", "") or ""
    base = os.path.basename(cwd) if cwd else ""
    if base and raw:
        return f"{base}-{raw[:8]}"
    return base or raw or "unknown"


def load_state():
    try:
        with open(STATE_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {"enabled": True, "voice": "auto"}


def load_flushed():
    """Return {msg_uuid: chunk_count_already_spoken}."""
    try:
        with open(FLUSH_FILE, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def save_flushed(d):
    try:
        with open(FLUSH_FILE, "w") as f:
            json.dump(d, f)
    except Exception:
        pass


def send_to_broker(text, voice="auto", session_id="unknown", pid=None):
    """Send a speak command to the PiTalk broker via TCP/NDJSON."""
    try:
        command = {
            "type": "speak",
            "text": text,
            "sourceApp": "claude-code",
            "sessionId": session_id,
        }
        if voice and voice != "auto":
            command["voice"] = voice
        if pid:
            command["pid"] = pid

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect((TTS_HOST, BROKER_PORT))
        sock.sendall(json.dumps(command).encode() + b"\n")

        # Read response
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(1024)
            if not chunk:
                break
            data += chunk
        sock.close()

        resp = json.loads(data.decode().strip())
        return resp.get("ok", False)
    except Exception:
        return False


def extract_voice_tags(text):
    """Extract all <voice>...</voice> content from text."""
    pattern = re.compile(r"<voice>(.*?)</voice>", re.DOTALL)
    matches = pattern.findall(text)
    # Strip any accidental nested markup
    cleaned = []
    for m in matches:
        clean = re.sub(r"<[^>]+>", " ", m).strip()
        clean = re.sub(r"\s+", " ", clean)
        clean = re.sub(r"\s+([.,!?;:])", r"\1", clean)
        if clean:
            cleaned.append(clean)
    return cleaned


def get_last_assistant_messages(transcript_path):
    """Read the transcript and get the last assistant message(s)."""
    if not transcript_path or not os.path.exists(transcript_path):
        return []

    messages = []
    try:
        with open(transcript_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                    if obj.get("type") == "assistant":
                        messages.append(obj)
                except json.JSONDecodeError:
                    continue
    except Exception:
        return []

    return messages


def main():
    debug("=== speak-response.py START ===")

    # Read hook input
    try:
        input_data = json.loads(sys.stdin.read())
    except Exception:
        input_data = {}

    debug(f"input keys: {list(input_data.keys())}")

    state = load_state()

    # Check if TTS is enabled
    if not state.get("enabled", True):
        debug("TTS disabled, exiting")
        sys.exit(0)

    # Skip stop-hook continuations to avoid duplicate speech
    if input_data.get("stop_hook_active"):
        debug("stop_hook_active=True, skipping")
        sys.exit(0)

    # Per-session sessionId from hook input (not state, which is shared and
    # gets stomped on every session-start).
    session_id = derive_session_id(input_data)
    voice = state.get("voice", "auto")
    pid = state.get("claude_pid", os.getpid())
    transcript_path = input_data.get("transcript_path", "")

    # Content comes from last_assistant_message (authoritative for THIS turn).
    # Reading from the transcript's tail is unsafe: when Claude Code resumes an
    # idle session, yesterday's last message still sits at the end of the
    # transcript, and we'd happily replay it as if it were the current reply.
    # The transcript is used only to find the matching UUID for dedup.
    full_text = ""
    last_msg = input_data.get("last_assistant_message")
    if isinstance(last_msg, str) and last_msg.strip():
        full_text = last_msg
    elif isinstance(last_msg, dict):
        content = last_msg.get("content") or last_msg.get("message", {}).get("content", "")
        if isinstance(content, list):
            full_text = " ".join(
                p.get("text", "") for p in content
                if isinstance(p, dict) and p.get("type") == "text"
            )
        elif isinstance(content, str):
            full_text = content

    if not full_text:
        debug("no last_assistant_message content, exit")
        sys.exit(0)

    # Find the transcript message whose text matches the hook payload, so we
    # can key dedup against flush-voice's mid-turn flushes. If nothing matches,
    # skip playback — that's safer than replaying a stale entry or duplicating
    # chunks that already played mid-turn.
    def _norm(s):
        return re.sub(r"\s+", " ", s).strip()

    target = _norm(full_text)
    msg_uuid = ""
    for attempt in range(8):
        messages = get_last_assistant_messages(transcript_path)
        for m in reversed(messages[-30:]):
            m_content = m.get("message", {}).get("content", "")
            if isinstance(m_content, list):
                m_text = " ".join(
                    p.get("text", "") for p in m_content
                    if isinstance(p, dict) and p.get("type") == "text"
                )
            elif isinstance(m_content, str):
                m_text = m_content
            else:
                m_text = ""
            if m_text and _norm(m_text) == target:
                msg_uuid = m.get("uuid", "")
                break
        if msg_uuid:
            debug(f"matched transcript msg {msg_uuid[:8]} on attempt {attempt} ({len(full_text)} chars)")
            break
        time.sleep(0.15 if attempt < 3 else 0.3)

    if not msg_uuid:
        debug("no transcript match for current turn; skipping (likely stale resumed session)")
        sys.exit(0)

    chunks = extract_voice_tags(full_text)
    flushed = load_flushed()
    already = flushed.get(msg_uuid, 0) if msg_uuid else 0
    new_chunks = chunks[already:]

    debug(f"total={len(chunks)} flushed={already} new={len(new_chunks)}")

    for chunk in new_chunks:
        ok = send_to_broker(chunk, voice=voice, session_id=session_id, pid=pid)
        debug(f"  sent '{chunk[:60]}' ok={ok}")

    if msg_uuid:
        flushed[msg_uuid] = len(chunks)
        save_flushed(flushed)

    print(json.dumps({"spoken": len(new_chunks)}))
    sys.exit(0)


if __name__ == "__main__":
    main()
