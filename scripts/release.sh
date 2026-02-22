#!/bin/bash
set -e

# Change to project root (parent of scripts/)
cd "$(dirname "$0")/.."

# Load environment
source ~/.env 2>/dev/null || true

# Release script for PiTalk
# Usage: ./scripts/release.sh 1.0.3
#        ./scripts/release.sh 1.0.3 --skip-notarize
#
# Prerequisites:
#   - Developer ID Application certificate in keychain
#   - App-specific password in ~/.env as APPLE_APP_PASSWORD
#   - create-dmg: brew install create-dmg

VERSION=$1
shift || true

# Configuration
APP_NAME="PiTalk"
BUNDLE_ID="com.pitalk.app"
SIGNING_IDENTITY="Developer ID Application: Swair Rajesh Shah (8B9YURJS4G)"
TEAM_ID="8B9YURJS4G"
APPLE_ID="swairshah@gmail.com"

# Parse flags
SKIP_NOTARIZE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize)
            SKIP_NOTARIZE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/release.sh <version>"
    echo "Example: ./scripts/release.sh 1.0.3"
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== PiTalk Release v${VERSION} ===${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if [ "$SKIP_NOTARIZE" = false ] && [ -z "$APPLE_APP_PASSWORD" ]; then
    echo -e "${RED}Error: APPLE_APP_PASSWORD not set in ~/.env${NC}"
    echo "Add it or use --skip-notarize"
    exit 1
fi

if ! command -v create-dmg &> /dev/null; then
    echo -e "${YELLOW}Installing create-dmg...${NC}"
    brew install create-dmg
fi

# 1. Update version in build script
echo -e "${YELLOW}📝 Updating version...${NC}"
sed -i '' "s/^VERSION=\"[^\"]*\"/VERSION=\"${VERSION}\"/" scripts/build-app.sh

# 2. Clean previous builds
echo -e "${YELLOW}Cleaning previous builds...${NC}"
rm -rf dist
mkdir -p dist

# 3. Build (always universal for releases)
echo -e "${YELLOW}🔨 Building universal binary (arm64 + x86_64)...${NC}"
./scripts/build-app.sh --universal

APP_DIR=".build/PiTalk.app"

# 4. Code sign the app bundle
echo -e "${YELLOW}🔏 Signing app bundle...${NC}"
codesign --force --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR/Contents/MacOS/ptts"

codesign --force --deep --options runtime \
    --sign "$SIGNING_IDENTITY" \
    "$APP_DIR"

# Verify signature
echo -e "${YELLOW}Verifying signature...${NC}"
codesign --verify --verbose=2 "$APP_DIR"
spctl --assess --verbose=2 "$APP_DIR" || true

if [ "$SKIP_NOTARIZE" = false ]; then
    # 5. Notarize the app (via ZIP)
    echo -e "${YELLOW}📦 Creating ZIP for app notarization...${NC}"
    ditto -c -k --keepParent "$APP_DIR" ".build/$APP_NAME.zip"

    echo -e "${YELLOW}📤 Submitting app for notarization...${NC}"
    xcrun notarytool submit ".build/$APP_NAME.zip" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait

    # Staple the app
    echo -e "${YELLOW}📎 Stapling notarization ticket to app...${NC}"
    xcrun stapler staple "$APP_DIR"

    # Verify
    echo -e "${YELLOW}Verifying app notarization...${NC}"
    xcrun stapler validate "$APP_DIR"
    spctl --assess --verbose=2 "$APP_DIR"
fi

# 6. Create DMG
echo -e "${YELLOW}📀 Creating DMG...${NC}"
DMG_PATH="dist/${APP_NAME}-${VERSION}.dmg"

# create-dmg returns non-zero on AppleScript cosmetic failures even when DMG is created
# Use hdiutil as a fallback if create-dmg fails
create-dmg \
    --volname "$APP_NAME" \
    --volicon "$APP_DIR/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "$APP_NAME.app" 150 190 \
    --app-drop-link 450 185 \
    --hide-extension "$APP_NAME.app" \
    --skip-jenkins \
    "$DMG_PATH" \
    "$APP_DIR" \
    2>&1 || true

if [ ! -f "$DMG_PATH" ]; then
    echo -e "${YELLOW}create-dmg failed, falling back to hdiutil...${NC}"
    STAGING_DIR=$(mktemp -d)
    cp -R "$APP_DIR" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" \
        -ov -format UDZO "$DMG_PATH"
    rm -rf "$STAGING_DIR"
fi

if [ ! -f "$DMG_PATH" ]; then
    echo -e "${RED}Error: DMG creation failed${NC}"
    exit 1
fi

# 7. Sign the DMG
echo -e "${YELLOW}🔏 Signing DMG...${NC}"
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_PATH"

if [ "$SKIP_NOTARIZE" = false ]; then
    # 8. Notarize the DMG
    echo -e "${YELLOW}📤 Submitting DMG for notarization...${NC}"
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait

    # 9. Staple the DMG
    echo -e "${YELLOW}📎 Stapling notarization ticket to DMG...${NC}"
    xcrun stapler staple "$DMG_PATH"

    # Verify
    echo -e "${YELLOW}Verifying DMG notarization...${NC}"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH" || true
else
    echo -e "${YELLOW}Skipping notarization (--skip-notarize)${NC}"
fi

# 10. Also create pi-talk extension zip
echo -e "${YELLOW}📦 Packaging pi-talk extension...${NC}"
zip -j dist/pi-talk-${VERSION}.zip Extensions/pi-talk/index.ts Extensions/pi-talk/package.json Extensions/pi-talk/README.md 2>/dev/null || true

# 11. Calculate SHA for Homebrew
echo ""
SHA=$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)
echo -e "📋 SHA256: ${GREEN}$SHA${NC}"

# 12. Update Homebrew cask
CASK_FILE=~/work/projects/homebrew-tap/Casks/pitalk.rb
if [ -f "$CASK_FILE" ]; then
    echo -e "${YELLOW}📝 Updating Homebrew cask...${NC}"
    sed -i '' "s/version \"[^\"]*\"/version \"${VERSION}\"/" "$CASK_FILE"
    sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"${SHA}\"/" "$CASK_FILE"
    echo -e "   Updated ${GREEN}$CASK_FILE${NC}"
fi

echo ""
echo -e "${GREEN}=== Release Build Complete ===${NC}"
echo ""
ls -lh "$DMG_PATH"
echo ""
echo -e "Next steps:"
echo ""
echo -e "  1. Test: ${GREEN}open $DMG_PATH${NC}"
echo -e "  2. Create GitHub release:"
echo ""
echo -e "     git tag -a v${VERSION} -m \"Release v${VERSION}\""
echo -e "     git push origin v${VERSION}"
echo ""
echo -e "     gh release create v${VERSION} \\"
echo -e "       dist/PiTalk-${VERSION}.dmg \\"
if [ -f "dist/pi-talk-${VERSION}.zip" ]; then
echo -e "       dist/pi-talk-${VERSION}.zip \\"
fi
echo -e "       --title \"PiTalk v${VERSION}\" \\"
echo -e "       --generate-notes"
echo ""
echo -e "  3. Push Homebrew tap:"
echo ""
echo -e "     cd ~/work/projects/homebrew-tap"
echo -e "     git add Casks/pitalk.rb"
echo -e "     git commit -m \"Update pitalk to ${VERSION}\""
echo -e "     git push"
echo ""
