#!/bin/bash
set -e

# Change to project root (parent of scripts/)
cd "$(dirname "$0")/.."

echo "🔨 Building PiTalk.app..."

# Ensure Git LFS files are pulled (models are stored in LFS)
echo "📥 Pulling Git LFS files..."
git lfs pull

# Build Swift app and CLI
swift build -c release --product PiTalk
swift build -c release --product ptts

# Install Rust TTS server from crates.io
echo "🦀 Installing pocket-tts-cli from GitHub fork..."
cargo install --git https://github.com/swairshah/pocket-tts --bin pocket-tts-cli --force --no-default-features

# Get the installed binary path
POCKET_TTS_BIN=$(which pocket-tts-cli)
if [ -z "$POCKET_TTS_BIN" ]; then
    echo "❌ Error: pocket-tts-cli not found after installation"
    exit 1
fi
echo "  ✓ Found pocket-tts-cli at: $POCKET_TTS_BIN"

# Create app bundle structure
APP_DIR=".build/PiTalk.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/models"

# Copy Swift executable
cp .build/release/PiTalk "$APP_DIR/Contents/MacOS/"

# Copy CLI tool
cp .build/release/ptts "$APP_DIR/Contents/MacOS/"

# Bundle the TTS server binary
cp "$POCKET_TTS_BIN" "$APP_DIR/Contents/Resources/"

# Bundle model files if present (optional - will download from HF if not bundled)
MODELS_DIR="Resources/models"
if [ -d "$MODELS_DIR" ] && [ -f "$MODELS_DIR/tts_b6369a24.safetensors" ]; then
    echo "📦 Bundling model files..."
    cp "$MODELS_DIR/tts_b6369a24.safetensors" "$APP_DIR/Contents/Resources/models/" 2>/dev/null || true
    cp "$MODELS_DIR/tokenizer.model" "$APP_DIR/Contents/Resources/models/" 2>/dev/null || true
    # Copy voice embeddings
    if [ -d "$MODELS_DIR/embeddings" ]; then
        mkdir -p "$APP_DIR/Contents/Resources/models/embeddings"
        cp "$MODELS_DIR/embeddings/"*.safetensors "$APP_DIR/Contents/Resources/models/embeddings/" 2>/dev/null || true
        echo "  ✓ Voice embeddings bundled"
    fi
    echo "  ✓ Model files bundled"
else
    echo "📥 Models not bundled - will download from HuggingFace on first run"
fi

# Copy app icon
cp Resources/icons/AppIcon.icns "$APP_DIR/Contents/Resources/"

# Copy menubar icons
cp Resources/icons/menubar-running.png Resources/icons/menubar-running@2x.png "$APP_DIR/Contents/Resources/"
cp Resources/icons/menubar-stopped.png Resources/icons/menubar-stopped@2x.png "$APP_DIR/Contents/Resources/"

# Copy pocket-tts config files
mkdir -p "$APP_DIR/Contents/Resources/config"
cp Resources/config/*.yaml "$APP_DIR/Contents/Resources/config/"
echo "  ✓ Config files bundled"



# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PiTalk</string>
    <key>CFBundleIdentifier</key>
    <string>com.pitalk.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PiTalk</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Code signing
SIGNING_IDENTITY="Developer ID Application: Swair Rajesh Shah (8B9YURJS4G)"

echo "🔏 Signing app..."
# Sign the embedded binaries first
codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/Resources/pocket-tts-cli"
codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_DIR/Contents/MacOS/ptts"

# Sign the main app
codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_DIR"

# Verify signature
codesign --verify --deep --strict "$APP_DIR" && echo "  ✓ Signature valid" || echo "  ✗ Signature invalid"

echo ""
echo "✅ Built: $APP_DIR"
echo "✅ Built: .build/release/ptts (CLI tool)"
echo ""
echo "To run the app:"
echo "  open $APP_DIR"
echo ""
echo "To install the CLI:"
echo "  sudo cp .build/release/ptts /usr/local/bin/"
echo ""

APP_SIZE=$(du -sh "$APP_DIR" | cut -f1)
echo "📦 App size: $APP_SIZE"

if [ -d "$MODELS_DIR" ] && [ -f "$MODELS_DIR/tts_b6369a24.safetensors" ]; then
    echo "   Models bundled - no HuggingFace token required!"
else
    echo "   Models will download from HuggingFace on first run."
    echo "   Make sure HF_TOKEN is set in your environment."
fi
