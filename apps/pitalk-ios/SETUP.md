# PiTalk iOS Setup

This folder intentionally does not touch the macOS app build.

## Open in Xcode (double-click)

The project is pre-generated at:

- `apps/pitalk-ios/PiTalkiOS.xcodeproj`

You can open it by double-clicking that file in Finder.

If the project needs regeneration after file moves:

```bash
cd apps/pitalk-ios
xcodegen generate
```

## First run on a real iPhone

In Xcode:

1. Select target `PiTalkiOS`.
2. Open **Signing & Capabilities**.
3. Pick your Apple Team.
4. Set a unique bundle identifier if needed.
5. Select your iPhone as the run destination.

## Required Info.plist keys

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

## Connect to PiTalk host

In iOS Settings tab inside the app:

- Host: your Mac tailnet DNS/IP
- Port: `18082`
- Token: same value as `PITALK_REMOTE_TOKEN`
  - Dev-only no-token mode: leave token empty and run the Mac app with `PITALK_REMOTE_ALLOW_INSECURE_NO_AUTH=1`

## Mac-side launch example

```bash
PITALK_REMOTE_BIND=0.0.0.0 \
PITALK_REMOTE_PORT=18082 \
PITALK_REMOTE_TOKEN=replace-with-strong-token \
./run-dev.sh
```

Dev-only no-token mode:

```bash
PITALK_REMOTE_BIND=0.0.0.0 \
PITALK_REMOTE_PORT=18082 \
PITALK_REMOTE_ALLOW_INSECURE_NO_AUTH=1 \
./run-dev.sh
```
