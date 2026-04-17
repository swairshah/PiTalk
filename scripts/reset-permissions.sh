#!/bin/bash
# Reset TCC permissions for PiTalk
# After running, relaunch the app to re-grant permissions via macOS prompts.

BUNDLE_ID="com.pitalk.app"

echo "Resetting TCC permissions for $BUNDLE_ID..."

tccutil reset Accessibility "$BUNDLE_ID"
tccutil reset Microphone "$BUNDLE_ID"
tccutil reset All "$BUNDLE_ID"

echo "Done! Relaunch PiTalk to re-grant permissions."
