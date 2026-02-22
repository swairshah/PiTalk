#!/bin/bash
set -e

# Change to project root (parent of scripts/)
cd "$(dirname "$0")/.."

echo "🔨 Building PiTalk.app..."

# Build Swift app and CLI
swift build -c release --product PiTalk
swift build -c release --product ptts

# Create app bundle structure
APP_DIR=".build/PiTalk.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy Swift executable
cp .build/release/PiTalk "$APP_DIR/Contents/MacOS/"

# Copy CLI tool
cp .build/release/ptts "$APP_DIR/Contents/MacOS/"

# Copy app icon
cp Resources/icons/AppIcon.icns "$APP_DIR/Contents/Resources/"

# Copy menubar icons
cp Sources/PiTalk/Resources/menubar_on.png "$APP_DIR/Contents/Resources/"
cp Sources/PiTalk/Resources/menubar_off.png "$APP_DIR/Contents/Resources/"

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
    <string>2.0.0</string>
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

echo ""
echo "✅ Built: $APP_DIR"
echo "✅ Built: .build/release/ptts (CLI tool)"
echo ""
echo "To run the app:"
echo "  open $APP_DIR"
echo ""
echo "To install the CLI:"
echo "  cp .build/release/ptts ~/.local/bin/"
echo ""

APP_SIZE=$(du -sh "$APP_DIR" | cut -f1)
echo "📦 App size: $APP_SIZE"
