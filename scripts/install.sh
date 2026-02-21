#!/bin/bash
set -e

echo ""
echo "🔊 PiTalk Installer"
echo "======================"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Get project root (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_PATH="$PROJECT_ROOT/.build/PiTalk.app"
EXTENSION_SRC="$PROJECT_ROOT/Extensions/pi"
CLI_SRC="$PROJECT_ROOT/.build/release/ptts"

# Check if running from the right directory
if [ ! -d "$SCRIPT_DIR" ]; then
    echo -e "${RED}Error: Could not determine script directory${NC}"
    exit 1
fi

# Step 1: Check for Homebrew
echo -e "${CYAN}[1/5]${NC} Checking for Homebrew..."
if command -v brew &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} Homebrew is installed"
else
    echo -e "  ${YELLOW}Homebrew not found. Installing...${NC}"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Add to path for Apple Silicon
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi

# Step 2: Install ffmpeg (includes ffplay)
echo ""
echo -e "${CYAN}[2/5]${NC} Checking for ffmpeg..."
if command -v ffplay &> /dev/null; then
    echo -e "  ${GREEN}✓${NC} ffplay is installed ($(which ffplay))"
else
    echo -e "  ${YELLOW}Installing ffmpeg...${NC}"
    brew install ffmpeg
    echo -e "  ${GREEN}✓${NC} ffmpeg installed"
fi

# Step 3: Install Pi extension
echo ""
echo -e "${CYAN}[3/5]${NC} Installing Pi extension..."
PI_EXT_DIR="$HOME/.pi/agent/extensions/pi-tts"

if [ -d "$EXTENSION_SRC" ]; then
    mkdir -p "$PI_EXT_DIR"
    cp "$EXTENSION_SRC/index.ts" "$PI_EXT_DIR/"
    echo -e "  ${GREEN}✓${NC} Extension installed to $PI_EXT_DIR"
else
    echo -e "  ${YELLOW}⚠${NC} Extension source not found at $EXTENSION_SRC"
    echo -e "  ${YELLOW}  You may need to manually install the pi extension${NC}"
fi

# Step 4: Install PiTalk.app
echo ""
echo -e "${CYAN}[4/5]${NC} Installing PiTalk.app..."

if [ -d "$APP_PATH" ]; then
    INSTALL_DIR="/Applications"
    INSTALLED_APP="$INSTALL_DIR/PiTalk.app"
    
    # Remove old version if exists
    if [ -d "$INSTALLED_APP" ]; then
        echo -e "  Removing old version..."
        rm -rf "$INSTALLED_APP"
    fi
    
    # Copy to Applications
    cp -R "$APP_PATH" "$INSTALL_DIR/"
    echo -e "  ${GREEN}✓${NC} Installed to $INSTALLED_APP"
    
    # Start the app
    echo ""
    echo -e "${CYAN}Starting PiTalk...${NC}"
    open "$INSTALLED_APP"
else
    echo -e "  ${YELLOW}⚠${NC} App not found at $APP_PATH"
    echo -e "  ${YELLOW}  Run ./scripts/build-app.sh first to build the app${NC}"
fi

# Step 5: Install ptts CLI
echo ""
echo -e "${CYAN}[5/5]${NC} Installing ptts CLI..."

if [ -f "$CLI_SRC" ]; then
    # Try /usr/local/bin first
    if [ -w "/usr/local/bin" ] || mkdir -p /usr/local/bin 2>/dev/null; then
        cp "$CLI_SRC" /usr/local/bin/ptts
        chmod +x /usr/local/bin/ptts
        echo -e "  ${GREEN}✓${NC} CLI installed to /usr/local/bin/ptts"
    else
        # Fall back to ~/.local/bin
        mkdir -p "$HOME/.local/bin"
        cp "$CLI_SRC" "$HOME/.local/bin/ptts"
        chmod +x "$HOME/.local/bin/ptts"
        echo -e "  ${GREEN}✓${NC} CLI installed to ~/.local/bin/ptts"
        
        # Check if ~/.local/bin is in PATH
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            echo -e "  ${YELLOW}⚠${NC} Add ~/.local/bin to your PATH:"
            echo -e "     ${YELLOW}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc${NC}"
        fi
    fi
else
    echo -e "  ${YELLOW}⚠${NC} CLI not found at $CLI_SRC"
    echo -e "  ${YELLOW}  Run ./scripts/build-app.sh first to build${NC}"
fi

# Done
echo ""
echo -e "${GREEN}==============================${NC}"
echo -e "${GREEN}✓ Installation complete!${NC}"
echo -e "${GREEN}==============================${NC}"
echo ""
echo "PiTalk should now be running in your menu bar."
echo "Look for the phone icon in the top-right of your screen."
echo ""
echo "To use with Pi:"
echo "  1. Restart Pi to load the extension"
echo "  2. The assistant will automatically use <voice> tags"
echo "  3. Use /tts-say to test: /tts-say Hello world"
echo ""
echo "Commands:"
echo "  /tts        - Toggle TTS on/off"
echo "  /tts-mute   - Mute audio (keeps voice tags)"
echo "  /tts-say    - Speak arbitrary text"
echo "  /tts-stop   - Stop current speech"
echo "  /tts-status - Show status"
echo ""
echo "CLI usage:"
echo "  ptts \"Hello world\"        # Speak text"
echo "  ptts -v alba \"Hello\"      # Different voice"
echo "  echo \"Hello\" | ptts       # Pipe text"
echo ""
echo "Global shortcut: Cmd+Shift+. to stop speech"
echo ""
