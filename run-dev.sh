#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH=".build/PiTalk.app"
APP_BIN="$APP_PATH/Contents/MacOS/PiTalk"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== PiTalk Dev Build & Run ===${NC}"

# Optionally load API keys from ~/.env without sourcing arbitrary shell code.
# Set PITALK_SKIP_ENV=1 to skip this entirely.
if [ "${PITALK_SKIP_ENV:-0}" != "1" ] && [ -f ~/.env ]; then
    echo -e "${YELLOW}Loading API keys from ~/.env (safe parse)...${NC}"
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim leading whitespace
        line="${line#"${line%%[![:space:]]*}"}"

        # Skip empty/comment lines
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue

        case "$line" in
            ELEVENLABS_API_KEY=*|ELEVEN_API_KEY=*|GOOGLE_TTS_API_KEY=*)
                key="${line%%=*}"
                value="${line#*=}"

                # Strip surrounding single/double quotes if present
                if [[ "$value" =~ ^\".*\"$ ]]; then
                    value="${value:1:${#value}-2}"
                elif [[ "$value" =~ ^\'.*\'$ ]]; then
                    value="${value:1:${#value}-2}"
                fi

                export "$key=$value"
                ;;
        esac
    done < ~/.env
fi

# Kill existing PiTalk
pkill -f "PiTalk" 2>/dev/null || true
lsof -ti:18081 2>/dev/null | xargs kill -9 2>/dev/null || true
lsof -ti:18083 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 0.5

# Build
echo -e "${YELLOW}Building...${NC}"
swift build

# Ensure app bundle exists
if [ ! -d "$APP_PATH" ]; then
    echo -e "${YELLOW}Creating app bundle...${NC}"
    ./scripts/build-app.sh
fi

# Update binary in app bundle with debug build
echo -e "${YELLOW}Updating app bundle with debug build...${NC}"
cp .build/debug/PiTalk "$APP_BIN"
codesign --force --sign - "$APP_PATH"

# Check for API key
if [ -n "${ELEVENLABS_API_KEY:-}" ] || [ -n "${ELEVEN_API_KEY:-}" ]; then
    echo -e "${GREEN}ElevenLabs API key found ✓${NC}"
else
    echo -e "${YELLOW}Note: No ElevenLabs API key found. Configure it in Settings.${NC}"
fi

# Run app bundle with debug logging enabled
echo -e "${GREEN}Launching PiTalk (debug mode via app bundle)...${NC}"
PITALK_DEBUG=1 "$APP_BIN" &
PID=$!

sleep 1
echo -e "${GREEN}PiTalk is running (PID: $PID)${NC}"
echo -e "Click the menubar icon to open the status panel."
echo ""
echo -e "To stop: ${YELLOW}pkill -f PiTalk${NC}"
echo -e "To test TTS: ${YELLOW}echo '{\"type\":\"speak\",\"text\":\"Hello world\"}' | nc localhost 18081${NC}"
