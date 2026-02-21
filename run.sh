#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_PATH=".build/PiTalk.app"
APP_BIN="$APP_PATH/Contents/MacOS/PiTalk"
PTTS_BIN="$APP_PATH/Contents/MacOS/ptts"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== PiTalk Build & Run ===${NC}"

# Kill existing PiTalk + embedded server
pkill -f "$APP_BIN" 2>/dev/null || true
pkill -f "pocket-tts-cli serve --port 18080" 2>/dev/null || true

# Build debug binaries
echo -e "${YELLOW}Building (swift build)...${NC}"
swift build

# Ensure app bundle exists (created by scripts/build-app.sh)
if [ ! -d "$APP_PATH" ]; then
  echo -e "${RED}Missing $APP_PATH${NC}"
  echo -e "Create it once with: ${YELLOW}./scripts/build-app.sh${NC}"
  exit 1
fi

# Replace app bundle binaries with fresh debug builds
echo -e "${YELLOW}Updating app bundle binaries...${NC}"
cp .build/debug/PiTalk "$APP_BIN"
cp .build/debug/ptts "$PTTS_BIN"

# Keep CLI in PATH in sync (if local bin exists)
if [ -d "$HOME/.local/bin" ]; then
  cp .build/debug/ptts "$HOME/.local/bin/ptts"
  chmod +x "$HOME/.local/bin/ptts"
fi

# Launch app
echo -e "${GREEN}Launching PiTalk...${NC}"
open "$APP_PATH"
sleep 2

# Quick health checks
if pgrep -f "$APP_BIN" >/dev/null; then
  echo -e "${GREEN}PiTalk process: running${NC}"
else
  echo -e "${RED}PiTalk process: not running${NC}"
fi

if curl -fsS http://127.0.0.1:18080/health >/dev/null 2>&1; then
  echo -e "${GREEN}TTS server (18080): healthy${NC}"
else
  echo -e "${RED}TTS server (18080): not healthy yet${NC}"
fi

if nc -z 127.0.0.1 18081 >/dev/null 2>&1; then
  echo -e "${GREEN}Broker (18081): listening${NC}"
else
  echo -e "${RED}Broker (18081): not listening${NC}"
fi

echo -e "${GREEN}Done.${NC}"
