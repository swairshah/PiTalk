#!/usr/bin/env python3
"""
PreToolUse hook: mid-turn flush of <voice> tags.

When Claude pauses to call a tool, we read the in-progress assistant message
from the transcript, extract any closed <voice>...</voice> tags, and send any
that haven't been flushed yet to the PiTalk broker. This gives users audio
feedback during a turn instead of waiting for the entire response to finish.

Dedup is per assistant message UUID — we remember how many chunks we've
already flushed for each message and only send the new ones. The Stop hook
shares the same state file so it doesn't re-speak chunks we already flushed.
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
FLUSH_FILE = "/tmp/loqui-tts-flushed.json"
DEBUG_LOG = "/tmp/loqui-tts-debug.log"


def debug(msg):
    try:
        with open(DEBUG_LOG, "a") as f:
            f.write(f"[{datetime.now().strftime('%H:%M:%S.%f')[:-3]}] flush: {msg}\n")
    except Exception:
        pass


def derive_session_id(input_data):
    """Display-friendly, per-session sessionId: "<cwd-basename>-<uuid[:8]>".

    Must stay identical to the derivation in style-reminder.py and
    speak-response.py so drains line up with enqueues.
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
    """Return {msg_uuid: chunk_count_already_flushed}."""
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
    """Extract all closed <voice>...</voice> chunks, in order."""
    pattern = re.compile(r"<voice>(.*?)</voice>", re.DOTALL)
    matches = pattern.findall(text)
    cleaned = []
    for m in matches:
        clean = re.sub(r"<[^>]+>", " ", m).strip()
        clean = re.sub(r"\s+", " ", clean)
        clean = re.sub(r"\s+([.,!?;:])", r"\1", clean)
        if clean:
            cleaned.append(clean)
    return cleaned


def get_recent_assistant_messages(transcript_path, limit=30):
    """
    Return the last `limit` assistant messages from the transcript.

    Claude Code splits each turn into multiple assistant messages — one per
    text chunk, one per tool_use, etc. So the latest message may be a
    tool_use with no text. We need to look back across recent messages and
    let per-UUID dedup decide which ones still have unspoken voice content.
    """
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
    return messages[-limit:]


def extract_text_from_message(msg):
    content = msg.get("message", {}).get("content", "")
    if isinstance(content, list):
        return " ".join(
            p.get("text", "") for p in content
            if isinstance(p, dict) and p.get("type") == "text"
        )
    if isinstance(content, str):
        return content
    return ""


def main():
    try:
        input_data = json.loads(sys.stdin.read())
    except Exception:
        input_data = {}

    debug(f"=== START === input keys: {list(input_data.keys())}")

    state = load_state()
    if not state.get("enabled", True):
        debug("disabled, exit")
        sys.exit(0)

    transcript_path = input_data.get("transcript_path", "")
    # Per-session sessionId from hook input (not state, which is shared and
    # gets stomped on every session-start).
    session_id = derive_session_id(input_data)
    voice = state.get("voice", "auto")
    pid = state.get("claude_pid", os.getpid())

    # Brief retry in case transcript hasn't flushed yet.
    messages = []
    for _ in range(3):
        messages = get_recent_assistant_messages(transcript_path)
        if messages:
            break
        time.sleep(0.1)

    if not messages:
        debug("no assistant messages in transcript")
        sys.exit(0)

    flushed = load_flushed()
    total_new = 0

    # Walk recent assistant messages oldest-to-newest. Per-UUID dedup means
    # text-only messages from earlier in the turn (which the latest tool_use
    # message replaced as "newest") will get their unspoken chunks flushed
    # the first time we see them, and skipped on subsequent fires.
    for msg in messages:
        msg_uuid = msg.get("uuid", "")
        if not msg_uuid:
            continue
        full_text = extract_text_from_message(msg)
        if not full_text:
            continue
        chunks = extract_voice_tags(full_text)
        if not chunks:
            continue
        already = flushed.get(msg_uuid, 0)
        new_chunks = chunks[already:]
        if not new_chunks:
            continue

        debug(f"msg {msg_uuid[:8]}: total={len(chunks)} flushed={already} new={len(new_chunks)}")
        for chunk in new_chunks:
            ok = send_to_broker(chunk, voice=voice, session_id=session_id, pid=pid)
            debug(f"  sent '{chunk[:60]}' ok={ok}")
        flushed[msg_uuid] = len(chunks)
        total_new += len(new_chunks)

    save_flushed(flushed)

    print(json.dumps({"flushed": total_new}))
    sys.exit(0)


if __name__ == "__main__":
    main()
