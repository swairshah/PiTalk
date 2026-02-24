# PiTalk iOS Setup

This folder intentionally does not touch the macOS app build.

## Open in Xcode

Project path:

- `apps/pitalk-ios/PiTalkiOS.xcodeproj`

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

## Required iOS permissions/keys

- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

## Connect to PiTalk host

In the iOS app Settings tab:

- Host: your Mac tailnet DNS/IP
- Port: `18082`
- Token: same value as `PITALK_REMOTE_TOKEN`
  - Dev no-token mode: leave token empty and run Mac with `PITALK_REMOTE_ALLOW_INSECURE_NO_AUTH=1`

## Mac-side launch examples

Token mode:

```bash
PITALK_REMOTE_BIND=0.0.0.0 \
PITALK_REMOTE_PORT=18082 \
PITALK_REMOTE_TOKEN=replace-with-strong-token \
./run-dev.sh
```

Dev no-token mode:

```bash
PITALK_REMOTE_BIND=0.0.0.0 \
PITALK_REMOTE_PORT=18082 \
PITALK_REMOTE_ALLOW_INSECURE_NO_AUTH=1 \
./run-dev.sh
```

## Quick verification checklist

- [ ] Connect iOS app to host profile
- [ ] Open a session and send text
- [ ] Hold-to-talk sends transcript text
- [ ] Toggle remote audio stream and verify foreground playback
- [ ] Pick a photo, confirm **Screenshot ready**, then tap **Send**
- [ ] Confirm session timeline shows **📷 Screenshot sent**
- [ ] Confirm remote Pi session receives screenshot path message
