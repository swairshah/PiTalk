#!/bin/bash
# Test script for Google Cloud Text-to-Speech API
#
# Prerequisites:
# 1. Create a Google Cloud project: https://console.cloud.google.com/
# 2. Enable the Cloud Text-to-Speech API
# 3. Either:
#    a) Set GOOGLE_TTS_API_KEY environment variable (simplest for testing)
#    b) Or use gcloud CLI: gcloud auth application-default login
#
# Usage:
#   GOOGLE_TTS_API_KEY=your-key ./scripts/test-google-tts.sh
#   # Or with gcloud auth:
#   ./scripts/test-google-tts.sh --gcloud
#
# Output: test-output.mp3 in current directory

set -e

TEXT="${1:-Hello! This is a test of Google Cloud Text to Speech.}"
OUTPUT_FILE="test-google-tts-output.mp3"
USE_GCLOUD=false

# Parse arguments
for arg in "$@"; do
  case $arg in
    --gcloud)
      USE_GCLOUD=true
      shift
      ;;
  esac
done

# Determine authentication method
if [ "$USE_GCLOUD" = true ]; then
  echo "Using gcloud application-default credentials..."
  if ! command -v gcloud &> /dev/null; then
    echo "Error: gcloud CLI not found. Install from https://cloud.google.com/sdk/docs/install"
    exit 1
  fi
  AUTH_HEADER="Authorization: Bearer $(gcloud auth application-default print-access-token)"
  API_URL="https://texttospeech.googleapis.com/v1/text:synthesize"
elif [ -n "$GOOGLE_TTS_API_KEY" ]; then
  echo "Using API key authentication..."
  AUTH_HEADER=""
  API_URL="https://texttospeech.googleapis.com/v1/text:synthesize?key=${GOOGLE_TTS_API_KEY}"
else
  echo "Error: No authentication configured."
  echo ""
  echo "Options:"
  echo "  1. Set GOOGLE_TTS_API_KEY environment variable"
  echo "     export GOOGLE_TTS_API_KEY=your-api-key"
  echo ""
  echo "  2. Use gcloud CLI (run with --gcloud flag)"
  echo "     gcloud auth application-default login"
  echo "     ./scripts/test-google-tts.sh --gcloud"
  echo ""
  echo "To get an API key:"
  echo "  1. Go to https://console.cloud.google.com/apis/credentials"
  echo "  2. Create credentials > API key"
  echo "  3. (Optional) Restrict key to Cloud Text-to-Speech API"
  exit 1
fi

echo "Testing Google Cloud TTS API..."
echo "Text: \"$TEXT\""
echo ""

# Build the request payload
PAYLOAD=$(cat <<EOF
{
  "input": {
    "text": "$TEXT"
  },
  "voice": {
    "languageCode": "en-US",
    "name": "en-US-Neural2-F"
  },
  "audioConfig": {
    "audioEncoding": "MP3",
    "speakingRate": 1.0,
    "pitch": 0
  }
}
EOF
)

# Make the API request
echo "Sending request..."

if [ -n "$AUTH_HEADER" ]; then
  RESPONSE=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -H "$AUTH_HEADER" \
    -d "$PAYLOAD")
else
  RESPONSE=$(curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")
fi

# Check for errors
if echo "$RESPONSE" | grep -q '"error"'; then
  echo "API Error:"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
  exit 1
fi

# Extract and decode the audio content
AUDIO_CONTENT=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['audioContent'])" 2>/dev/null)

if [ -z "$AUDIO_CONTENT" ]; then
  echo "Error: No audio content in response"
  echo "Response:"
  echo "$RESPONSE" | head -c 500
  exit 1
fi

# Decode base64 and save to file
echo "$AUDIO_CONTENT" | base64 -d > "$OUTPUT_FILE"

# Get file size
FILE_SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
echo ""
echo "✓ Success! Audio saved to: $OUTPUT_FILE ($FILE_SIZE)"
echo ""

# Try to play the audio
if command -v ffplay &> /dev/null; then
  echo "Playing audio with ffplay..."
  ffplay -nodisp -autoexit "$OUTPUT_FILE" 2>/dev/null
elif command -v afplay &> /dev/null; then
  echo "Playing audio with afplay..."
  afplay "$OUTPUT_FILE"
else
  echo "To play: ffplay $OUTPUT_FILE"
fi
