# Releasing PiTalk

## Quick Release (one command)

```bash
./scripts/release.sh <version>
```

Example:

```bash
./scripts/release.sh 1.0.5
```

This single command handles everything:

1. Updates version in `scripts/build-app.sh`
2. Builds **universal binary** (arm64 + x86_64) — works on both Apple Silicon and Intel Macs
3. Copies the **SPM resource bundle** (`PiTalk_PiTalk.bundle`) into the app
4. Code signs the app with Developer ID
5. **Notarizes the app** (via ZIP upload) and staples the ticket
6. Creates a DMG with Applications symlink
7. **Notarizes the DMG** and staples the ticket
8. Packages the pi-talk extension ZIP
9. Calculates SHA256 and updates the **Homebrew cask**

### After the script finishes

Commit, tag, create GitHub release, and push the Homebrew tap:

```bash
# Commit and tag
git add scripts/build-app.sh
git commit -m "v1.0.5: <description>"
git push origin main
git tag -a v1.0.5 -m "Release v1.0.5"
git push origin v1.0.5

# GitHub release
gh release create v1.0.5 \
  dist/PiTalk-1.0.5.dmg \
  dist/pi-talk-1.0.5.zip \
  --title "PiTalk v1.0.5" \
  --generate-notes

# Homebrew tap
cd ~/work/projects/homebrew-tap
git add Casks/pitalk.rb
git commit -m "Update pitalk to 1.0.5"
git push
```

## Prerequisites

- **Developer ID Application certificate** in Keychain (`Developer ID Application: Swair Rajesh Shah (8B9YURJS4G)`)
- **App-specific password** in `~/.env` as `APPLE_APP_PASSWORD`
- **create-dmg**: `brew install create-dmg`
- **gh** (GitHub CLI): `brew install gh`

## Skip Notarization (for testing)

```bash
./scripts/release.sh 1.0.5 --skip-notarize
```

## Debugging Failed Notarization

```bash
# Check submission log
xcrun notarytool log <SUBMISSION_ID> \
  --apple-id swairshah@gmail.com \
  --password "$APPLE_APP_PASSWORD" \
  --team-id 8B9YURJS4G
```

## Verifying a Build

```bash
# Check it's universal
file .build/PiTalk.app/Contents/MacOS/PiTalk
# → Mach-O universal binary with 2 architectures: [x86_64] [arm64]

# Check resource bundle is included
ls .build/PiTalk.app/Contents/Resources/PiTalk_PiTalk.bundle
# → Must exist, otherwise app crashes on launch

# Check signing
codesign --verify --verbose=2 .build/PiTalk.app

# Check notarization
spctl --assess --verbose=2 .build/PiTalk.app
# → should say "accepted" and "source=Notarized Developer ID"
```

## Debugging Launch Failures on Other Machines

If the app won't open on another Mac:

```bash
# Check Console.app — filter by "PiTalk"

# Check crash reports
ls ~/Library/Logs/DiagnosticReports/PiTalk*

# Check system log
log show --predicate 'process == "PiTalk"' --last 5m

# Check quarantine (if downloaded from internet)
xattr -l /Applications/PiTalk.app
xattr -cr /Applications/PiTalk.app  # clear quarantine

# Check notarization
spctl --assess --verbose=2 /Applications/PiTalk.app
codesign --verify --deep --verbose=2 /Applications/PiTalk.app
```

## Architecture Notes

### Why we build universal

The `--universal` flag passes `--arch arm64 --arch x86_64` to `swift build`, producing a fat binary that runs natively on both Apple Silicon and Intel Macs.

### Why we notarize the app AND the DMG

Previous versions only notarized the DMG. This caused Gatekeeper to block the app on other machines because the app binary itself wasn't notarized. Following the pattern from [Hearsay](../hearsay), we now:

1. Notarize the app (via ZIP) → staple the `.app`
2. Create the DMG from the stapled app
3. Notarize the DMG → staple the `.dmg`

### Why we copy PiTalk_PiTalk.bundle

PiTalk uses Swift Package Manager, which builds the executable and resource bundle as **separate outputs**. Unlike Xcode (`xcodebuild`), SPM does not create an `.app` bundle — `build-app.sh` assembles it manually.

The generated `resource_bundle_accessor.swift` looks for `PiTalk_PiTalk.bundle` in:
1. `Bundle.main.resourceURL` (inside the `.app` → `Contents/Resources/`)
2. A hardcoded absolute path to the local `.build/` directory (fallback)

The fallback path masks the bug on the build machine — the app works fine locally even without the bundle in the `.app`. On any other machine, that path doesn't exist and the app crashes with `fatalError("unable to find bundle named PiTalk_PiTalk")`.

**This is why the bundle must be explicitly copied into the app.**

## Users Install With

```bash
brew tap swairshah/tap
brew install --cask pitalk
```
