#!/bin/bash
# jump-to-pid.sh - Jump to a pi session by PID
# Usage: ./jump-to-pid.sh <PID>

PID="$1"
if [ -z "$PID" ]; then
    echo "Usage: $0 <PID>"
    exit 1
fi

# Get telemetry for this PID
TELEMETRY=""
for f in ~/.pi/agent/telemetry/instances/*.json; do
    [ -f "$f" ] || continue
    T=$(jq -r "select(.process.pid == $PID)" "$f" 2>/dev/null)
    if [ -n "$T" ]; then
        TELEMETRY="$T"
        break
    fi
done

if [ -z "$TELEMETRY" ]; then
    echo "PID $PID not found"
    exit 1
fi

MUX=$(echo "$TELEMETRY" | jq -r '.routing.mux // empty')
MUX_SESSION=$(echo "$TELEMETRY" | jq -r '.routing.muxSession // empty')
TMUX_PANE=$(echo "$TELEMETRY" | jq -r '.routing.tmux.paneTarget // empty')
ZELLIJ_TAB=$(echo "$TELEMETRY" | jq -r '.routing.zellij.matchedTab.index // empty')

if [ "$MUX" = "tmux" ] && [ -n "$TMUX_PANE" ]; then
    osascript -e 'tell application "Ghostty" to activate'
    WINDOW_TARGET=$(echo "$TMUX_PANE" | sed 's/\.[0-9]*$//')
    tmux select-window -t "$WINDOW_TARGET" 2>/dev/null || true
    tmux select-pane -t "$TMUX_PANE" 2>/dev/null || true
    echo "ok"
    
elif [ "$MUX" = "zellij" ] && [ -n "$ZELLIJ_TAB" ] && [ -n "$MUX_SESSION" ]; then
    osascript -e 'tell application "Ghostty" to activate'
    zellij -s "$MUX_SESSION" action go-to-tab "$ZELLIJ_TAB" 2>/dev/null || true
    echo "ok"
    
else
    # Ghostty raw splits - use keyboard to cycle tabs
    osascript - "$PID" <<'APPLESCRIPT'
on run argv
    set targetPID to item 1 of argv
    -- Use more specific pattern to avoid false matches in command output
    -- Status bar format is: ↓{PID} 🔊 (with space before emoji)
    set searchStr to "↓" & targetPID & " "
    
    tell application "Ghostty" to activate
    delay 0.05
    
    tell application "System Events"
        tell process "Ghostty"
            -- Get tab count
            set tabGroup to first UI element of window 1 whose role is "AXTabGroup"
            set tabCount to count of (every UI element of tabGroup whose role is "AXRadioButton")
            
            -- Check current tab first
            set allElems to entire contents of window 1
            repeat with elem in allElems
                try
                    if role of elem is "AXTextArea" then
                        set txt to value of elem
                        -- Only check last 200 chars (status bar area)
                        if (length of txt) > 200 then
                            set lastPart to text -200 thru -1 of txt
                        else
                            set lastPart to txt
                        end if
                        if lastPart contains searchStr then
                            set focused of elem to true
                            return "ok"
                        end if
                    end if
                end try
            end repeat
            
            -- Cycle through remaining tabs using Cmd+Shift+]
            repeat (tabCount - 1) times
                keystroke "]" using {command down, shift down}
                delay 0.1
                
                set allElems to entire contents of window 1
                repeat with elem in allElems
                    try
                        if role of elem is "AXTextArea" then
                            set txt to value of elem
                            -- Only check last 200 chars (status bar area) to avoid false matches
                            if (length of txt) > 200 then
                                set lastPart to text -200 thru -1 of txt
                            else
                                set lastPart to txt
                            end if
                            if lastPart contains searchStr then
                                set focused of elem to true
                                return "ok"
                            end if
                        end if
                    end try
                end repeat
            end repeat
            
            return "not found"
        end tell
    end tell
end run
APPLESCRIPT
fi
