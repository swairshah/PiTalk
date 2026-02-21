# Releasing Loqui

This project now has an automated release script:

```bash
./scripts/release.sh <version>
```

Example:

```bash
./scripts/release.sh 1.2.0
```

---

## What the script does

`scripts/release.sh` will:

1. Update `CFBundleShortVersionString` in `scripts/build-app.sh`
2. Build Loqui + `ptts`
3. Bundle `pocket-tts-cli` + model files into `.build/Loqui.app`
4. Sign the app
5. Zip to `dist/Loqui-<version>.zip`
6. Notarize with Apple (`xcrun notarytool`) and staple ticket
7. Re-zip stapled app
8. Zip pi extension to `dist/pi-talk-<version>.zip`
9. Print SHA256 and update `~/work/projects/homebrew-tap/Casks/loqui.rb` (if present)

---

## Prerequisites

- Apple notarization credentials stored in keychain profile used by script (`AC_PASSWORD`)
- Developer ID signing identity available on your machine
- `gh` CLI installed (for GitHub release step)

Optional one-time setup:

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id "<apple-id>" \
  --team-id "8B9YURJS4G" \
  --password "<app-specific-password>"
```

---

## Manual steps after script completes

### 1) Create and push git tag

```bash
VERSION="1.2.0"

git tag -a v${VERSION} -m "Release v${VERSION}"
git push origin v${VERSION}
```

### 2) Create GitHub release

```bash
VERSION="1.2.0"

gh release create v${VERSION} \
  dist/Loqui-${VERSION}.zip \
  dist/pi-talk-${VERSION}.zip \
  --title "Loqui v${VERSION}" \
  --notes "Release notes"
```

### 3) Push Homebrew tap update

```bash
cd ~/work/projects/homebrew-tap
git add Casks/loqui.rb
git commit -m "Update loqui to ${VERSION}"
git push
```

---

## pi extension (npm)

The script only creates `dist/pi-talk-<version>.zip`.
Publishing `@swairshah/pi-talk` to npm is a separate step and can be done later.

---

## Post-install notes for users

After `brew install loqui`:

1. Open Loqui.app (menu bar app)
2. In Pi, install extension:
   ```bash
   pi install npm:@swairshah/pi-talk
   ```
3. Restart Pi if needed so extension loads
