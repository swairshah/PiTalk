# Releasing PiTalk

## 1. Bump version

Update `scripts/build-app.sh`:
- `VERSION="1.0.0"` at the top — user-facing version
- `CFBundleVersion` in the Info.plist section — increment build number

## 2. Build (Universal Binary)

```bash
# Build universal binary and create app bundle
./scripts/build-app.sh --universal

# Verify universal binary
file .build/PiTalk.app/Contents/MacOS/PiTalk
# Should show: Mach-O universal binary with 2 architectures: [x86_64] [arm64]
```

## 3. Sign

```bash
codesign --force --deep --options runtime --timestamp \
  --entitlements Sources/PiTalk/PiTalk.entitlements \
  --sign "Developer ID Application" \
  .build/PiTalk.app
```

## 4. Create DMG & Notarize

```bash
VERSION="1.0.0"  # Match version from step 1

mkdir -p dist
hdiutil create -volname "PiTalk" -srcfolder .build/PiTalk.app -ov -format UDZO dist/PiTalk-$VERSION.dmg

xcrun notarytool submit dist/PiTalk-$VERSION.dmg \
  --keychain-profile "notarytool" \
  --wait
```

If it fails, check the log:
```bash
xcrun notarytool log SUBMISSION_ID --keychain-profile "notarytool"
```

## 5. Staple

```bash
xcrun stapler staple dist/PiTalk-$VERSION.dmg
```

## 6. Commit & Tag

```bash
git add scripts/build-app.sh
git commit -m "Bump version to $VERSION"
git tag -a v$VERSION -m "Release v$VERSION"
git push origin main
git push origin v$VERSION
```

## 7. GitHub release

```bash
gh release create v$VERSION dist/PiTalk-$VERSION.dmg \
  --title "PiTalk v$VERSION" \
  --notes "Release notes here"
```

## 8. Update Homebrew tap

```bash
# Get SHA
shasum -a 256 dist/PiTalk-$VERSION.dmg

# Create/update ~/work/projects/homebrew-tap/Casks/pitalk.rb
```

Example cask file:
```ruby
cask "pitalk" do
  version "1.0.0"
  sha256 "YOUR_SHA256_HERE"

  url "https://github.com/swairshah/pi-talk-app/releases/download/v#{version}/PiTalk-#{version}.dmg"
  name "PiTalk"
  desc "Voice interface for pi coding agent"
  homepage "https://github.com/swairshah/pi-talk-app"

  depends_on macos: ">= :ventura"

  app "PiTalk.app"

  zap trash: [
    "~/Library/Application Support/PiTalk",
    "~/Library/Preferences/com.pitalk.app.plist",
  ]

  caveats <<~EOS
    PiTalk requires Microphone and Accessibility permissions.
    
    On first launch, grant accessibility access when prompted.
  EOS
end
```

Then push the tap:
```bash
cd ~/work/projects/homebrew-tap
git add Casks/pitalk.rb
git commit -m "Add/update pitalk to $VERSION"
git push
```

## 9. Users can install with:

```bash
brew tap swairshah/tap
brew install --cask pitalk
```
