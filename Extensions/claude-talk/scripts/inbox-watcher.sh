#!/bin/bash
# inbox-watcher.sh — Watches for voice input messages and types them into Claude Code's terminal
#
# Polls ~/.pi/agent/pitalk-inbox/<PID>/ for JSON message files.
# When found, extracts the text and pastes it into the active terminal.
#
# Started as a background process by session-start.py
# Killed by session-end.py or when the PID file is removed.

INBOX_DIR="$1"
PID_FILE="$2"
POLL_INTERVAL="${3:-0.5}"

if [ -z "$INBOX_DIR" ] || [ -z "$PID_FILE" ]; then
    echo "Usage: inbox-watcher.sh <inbox_dir> <pid_file> [poll_interval]" >&2
    exit 1
fi

# Write our PID
echo $$ > "$PID_FILE"

# Ensure inbox dir exists
mkdir -p "$INBOX_DIR"

# Cleanup on exit
cleanup() {
    rm -f "$PID_FILE"
    exit 0
}
trap cleanup EXIT INT TERM

# Paste text into the frontmost terminal using clipboard + Cmd+V + Enter
paste_into_terminal() {
    local text="$1"
    
    # Save current clipboard
    local old_clipboard
    old_clipboard=$(pbpaste 2>/dev/null)
    
    # Copy our text to clipboard
    printf '%s' "$text" | pbcopy
    
    # Small delay to ensure clipboard is set
    sleep 0.1
    
    # Paste and press Enter
    osascript -e '
        tell application "System Events"
            keystroke "v" using command down
            delay 0.1
            keystroke return
        end tell
    ' 2>/dev/null
    
    # Restore old clipboard after a short delay
    sleep 0.3
    printf '%s' "$old_clipboard" | pbcopy 2>/dev/null
}

# Main poll loop
while true; do
    # Check if we should stop
    if [ ! -f "$PID_FILE" ]; then
        exit 0
    fi
    
    # Check for message files
    if [ -d "$INBOX_DIR" ]; then
        for msg_file in "$INBOX_DIR"/*.json; do
            [ -f "$msg_file" ] || continue
            
            # Extract text from JSON
            text=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        msg = json.load(f)
    print(msg.get('text', ''), end='')
except:
    pass
" "$msg_file" 2>/dev/null)
            
            # Remove the message file
            rm -f "$msg_file"
            
            # Paste it into the terminal if we got text
            if [ -n "$text" ]; then
                paste_into_terminal "$text"
            fi
        done
    fi
    
    sleep "$POLL_INTERVAL"
done
