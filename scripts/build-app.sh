#!/bin/bash
set -e

# Change to project root (parent of scripts/)
cd "$(dirname "$0")/.."

# Version - update this for releases
VERSION="1.1.5"

echo "🔨 Building PiTalk.app v$VERSION..."

UNIVERSAL=false
BUNDLE_MODELS=false

for arg in "$@"; do
    case "$arg" in
        --universal)
            UNIVERSAL=true
            ;;
        --bundle-models)
            BUNDLE_MODELS=true
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Usage: ./scripts/build-app.sh [--universal] [--bundle-models]"
            exit 1
            ;;
    esac
done

if [ "$UNIVERSAL" = true ]; then
    echo "Building universal binary (arm64 + x86_64)..."
    swift build -c release --arch arm64 --arch x86_64 --product PiTalk
    swift build -c release --arch arm64 --arch x86_64 --product ptts
    BINARY_PATH=".build/apple/Products/Release"
else
    echo "Building for current architecture..."
    swift build -c release --product PiTalk
    swift build -c release --product ptts
    BINARY_PATH=".build/release"
fi

# Create app bundle structure
APP_DIR=".build/PiTalk.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy Swift executable
cp "$BINARY_PATH/PiTalk" "$APP_DIR/Contents/MacOS/"

# Copy CLI tool
cp "$BINARY_PATH/ptts" "$APP_DIR/Contents/MacOS/"

# Bundle local Rust runtime if available (for optional on-device TTS mode)
POCKET_TTS_BIN=""
for CANDIDATE in "$(command -v pocket-tts-cli 2>/dev/null || true)" \
                 "$HOME/.cargo/bin/pocket-tts-cli" \
                 "/opt/homebrew/bin/pocket-tts-cli" \
                 "/usr/local/bin/pocket-tts-cli"; do
    if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then
        POCKET_TTS_BIN="$CANDIDATE"
        break
    fi
done

if [ -n "$POCKET_TTS_BIN" ]; then
    cp "$POCKET_TTS_BIN" "$APP_DIR/Contents/Resources/pocket-tts-cli"
    chmod +x "$APP_DIR/Contents/Resources/pocket-tts-cli"
    echo "Bundled pocket-tts-cli: $POCKET_TTS_BIN"
else
    echo "⚠️  pocket-tts-cli not found; Local TTS mode will require external installation"
fi

if [ "$BUNDLE_MODELS" = true ]; then
    # Bundle local model files if requested (Loqui-style full package)
    MODELS_DIR="Resources/models"
    if [ ! -d "$MODELS_DIR" ] || [ ! -f "$MODELS_DIR/tts_b6369a24.safetensors" ]; then
        if [ -d "../Loqui/Resources/models" ] && [ -f "../Loqui/Resources/models/tts_b6369a24.safetensors" ]; then
            MODELS_DIR="../Loqui/Resources/models"
        fi
    fi

    if [ -d "$MODELS_DIR" ] && [ -f "$MODELS_DIR/tts_b6369a24.safetensors" ]; then
        mkdir -p "$APP_DIR/Contents/Resources/models"
        cp "$MODELS_DIR/tts_b6369a24.safetensors" "$APP_DIR/Contents/Resources/models/" 2>/dev/null || true
        cp "$MODELS_DIR/tokenizer.model" "$APP_DIR/Contents/Resources/models/" 2>/dev/null || true
        mkdir -p "$APP_DIR/Contents/Resources/models/embeddings"
        if [ -d "$MODELS_DIR/embeddings" ]; then
            cp "$MODELS_DIR/embeddings/"*.safetensors "$APP_DIR/Contents/Resources/models/embeddings/" 2>/dev/null || true
        else
            # Compatibility: older Loqui layout stores voice embeddings at the models root.
            for voice_file in "$MODELS_DIR"/*.safetensors; do
                [ -e "$voice_file" ] || continue
                base_name="$(basename "$voice_file")"
                if [ "$base_name" != "tts_b6369a24.safetensors" ]; then
                    cp "$voice_file" "$APP_DIR/Contents/Resources/models/embeddings/" 2>/dev/null || true
                fi
            done
        fi
        echo "Bundled local model files from $MODELS_DIR"
    else
        echo "⚠️  --bundle-models passed, but no model files found (checked Resources/models and ../Loqui/Resources/models)."
    fi
else
    echo "Skipping model bundling (default lightweight app package)."
fi

# Copy local runtime config files if present
CONFIG_DIR="Resources/config"
if [ ! -d "$CONFIG_DIR" ] || [ ! -f "$CONFIG_DIR/b6369a24.yaml" ]; then
    if [ -d "../Loqui/Resources/config" ] && [ -f "../Loqui/Resources/config/b6369a24.yaml" ]; then
        CONFIG_DIR="../Loqui/Resources/config"
    fi
fi
if [ -d "$CONFIG_DIR" ]; then
    mkdir -p "$APP_DIR/Contents/Resources/config"
    cp "$CONFIG_DIR"/*.yaml "$APP_DIR/Contents/Resources/config/" 2>/dev/null || true
    echo "Bundled runtime config files from $CONFIG_DIR"
else
    echo "⚠️  No runtime config dir found (checked Resources/config and ../Loqui/Resources/config)"
fi

# Copy app icon
cp Resources/icons/AppIcon.icns "$APP_DIR/Contents/Resources/"

# Copy SPM resource bundle (contains Assets.car and Resources/)
if [ -d "$BINARY_PATH/PiTalk_PiTalk.bundle" ]; then
    echo "Copying resource bundle PiTalk_PiTalk.bundle..."
    cp -R "$BINARY_PATH/PiTalk_PiTalk.bundle" "$APP_DIR/Contents/Resources/"
else
    echo "⚠️  Warning: PiTalk_PiTalk.bundle not found at $BINARY_PATH"
    echo "   The app may fail to launch without its resource bundle."
fi

# Copy menubar icons (also keep at top level for backward compat)
cp Sources/PiTalk/Resources/menubar_on.png "$APP_DIR/Contents/Resources/"
cp Sources/PiTalk/Resources/menubar_off.png "$APP_DIR/Contents/Resources/"

# Create Info.plist (note: no quotes around EOF to allow variable expansion)
cat > "$APP_DIR/Contents/Info.plist" << EOF
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
    <string>$VERSION</string>
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
    <key>NSMicrophoneUsageDescription</key>
    <string>PiTalk monitors microphone activity to pause speech when you're talking.</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo ""
echo "✅ Built: $APP_DIR"
echo "✅ Built: $BINARY_PATH/ptts (CLI tool)"
echo ""
echo "To run the app:"
echo "  open $APP_DIR"
echo ""
echo "To install the CLI:"
echo "  cp $BINARY_PATH/ptts ~/.local/bin/"
echo ""

APP_SIZE=$(du -sh "$APP_DIR" | cut -f1)
echo "📦 App size: $APP_SIZE"
