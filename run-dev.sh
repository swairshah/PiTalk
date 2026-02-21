#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== PiTalk Dev Build & Run ===${NC}"

# Load API keys from ~/.env
if [ -f ~/.env ]; then
    echo -e "${YELLOW}Loading ~/.env...${NC}"
    set -a
    source ~/.env
    set +a
fi

# Kill existing PiTalk
pkill -f ".build/debug/PiTalk" 2>/dev/null || true
lsof -ti:18081 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 0.5

# Build
echo -e "${YELLOW}Building...${NC}"
swift build

# Check for API key
if [ -n "${ELEVENLABS_API_KEY:-}" ] || [ -n "${ELEVEN_API_KEY:-}" ]; then
    echo -e "${GREEN}ElevenLabs API key found ✓${NC}"
else
    echo -e "${YELLOW}Note: No ElevenLabs API key found. Configure it in Settings.${NC}"
fi

# Run directly with debug logging enabled
echo -e "${GREEN}Launching PiTalk (debug mode)...${NC}"
PITALK_DEBUG=1 .build/debug/PiTalk &
PID=$!

sleep 1
echo -e "${GREEN}PiTalk is running (PID: $PID)${NC}"
echo -e "Click the menubar icon to open the status panel."
echo ""
echo -e "To stop: ${YELLOW}pkill -f PiTalk${NC}"
echo -e "To test TTS: ${YELLOW}echo '{\"type\":\"speak\",\"text\":\"Hello world\"}' | nc localhost 18081${NC}"
