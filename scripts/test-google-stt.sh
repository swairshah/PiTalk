#!/bin/bash
# Test script for Google Cloud Speech-to-Text API
#
# Usage:
#   GOOGLE_TTS_API_KEY=your-key ./scripts/test-google-stt.sh [audio-file]
#
# If no audio file is provided, it will record 5 seconds of audio first.

set -e

AUDIO_FILE="${1:-}"
API_KEY="${GOOGLE_TTS_API_KEY:-}"

if [ -z "$API_KEY" ]; then
  # Try to load from ~/.env
  if [ -f ~/.env ]; then
    API_KEY=$(grep "^GOOGLE_TTS_API_KEY=" ~/.env | cut -d'=' -f2 | tr -d '"' | tr -d "'")
  fi
fi

if [ -z "$API_KEY" ]; then
  echo "Error: GOOGLE_TTS_API_KEY not set"
  echo "Set it in environment or ~/.env"
  exit 1
fi

# If no audio file provided, record some
if [ -z "$AUDIO_FILE" ]; then
  echo "No audio file provided. Recording 5 seconds of audio..."
  echo "Speak now!"
  
  AUDIO_FILE="/tmp/test-stt-recording.wav"
  
  # Record using sox (if available) or ffmpeg
  if command -v rec &> /dev/null; then
    rec -q "$AUDIO_FILE" trim 0 5
  elif command -v ffmpeg &> /dev/null; then
    ffmpeg -y -f avfoundation -i ":0" -t 5 -ar 16000 -ac 1 "$AUDIO_FILE" 2>/dev/null
  else
    echo "Error: Need 'sox' or 'ffmpeg' to record audio"
    echo "Install with: brew install sox"
    exit 1
  fi
  
  echo "Recording complete!"
fi

if [ ! -f "$AUDIO_FILE" ]; then
  echo "Error: Audio file not found: $AUDIO_FILE"
  exit 1
fi

echo "Transcribing: $AUDIO_FILE"
echo ""

# Get file extension and set encoding
EXT="${AUDIO_FILE##*.}"
case "$EXT" in
  wav)
    ENCODING="LINEAR16"
    ;;
  flac)
    ENCODING="FLAC"
    ;;
  mp3)
    ENCODING="MP3"
    ;;
  *)
    ENCODING="ENCODING_UNSPECIFIED"
    ;;
esac

# Convert audio to base64
AUDIO_BASE64=$(base64 -i "$AUDIO_FILE")

# Build request
REQUEST=$(cat <<EOF
{
  "config": {
    "encoding": "$ENCODING",
    "sampleRateHertz": 16000,
    "languageCode": "en-US",
    "enableAutomaticPunctuation": true
  },
  "audio": {
    "content": "$AUDIO_BASE64"
  }
}
EOF
)

# Send request
RESPONSE=$(curl -s -X POST \
  "https://speech.googleapis.com/v1/speech:recognize?key=$API_KEY" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$REQUEST")

# Check for errors
if echo "$RESPONSE" | grep -q '"error"'; then
  echo "API Error:"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
  exit 1
fi

# Extract transcription
TRANSCRIPT=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('results', [])
    for r in results:
        alts = r.get('alternatives', [])
        if alts:
            print(alts[0].get('transcript', ''))
except:
    pass
" 2>/dev/null)

if [ -z "$TRANSCRIPT" ]; then
  echo "No speech detected or empty response"
  echo "Raw response:"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
else
  echo "✓ Transcription:"
  echo "$TRANSCRIPT"
fi
