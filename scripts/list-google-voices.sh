#!/bin/bash
# List available Google Cloud TTS voices
#
# Usage:
#   GOOGLE_TTS_API_KEY=your-key ./scripts/list-google-voices.sh
#   # Or filter by language:
#   GOOGLE_TTS_API_KEY=your-key ./scripts/list-google-voices.sh en-US
#   GOOGLE_TTS_API_KEY=your-key ./scripts/list-google-voices.sh en-GB

set -e

LANGUAGE_FILTER="${1:-}"

# Determine authentication
if [ -n "$GOOGLE_TTS_API_KEY" ]; then
  API_URL="https://texttospeech.googleapis.com/v1/voices?key=${GOOGLE_TTS_API_KEY}"
  AUTH_HEADER=""
else
  if ! command -v gcloud &> /dev/null; then
    echo "Error: Set GOOGLE_TTS_API_KEY or install gcloud CLI"
    exit 1
  fi
  API_URL="https://texttospeech.googleapis.com/v1/voices"
  AUTH_HEADER="Authorization: Bearer $(gcloud auth application-default print-access-token)"
fi

echo "Fetching available voices..."

if [ -n "$AUTH_HEADER" ]; then
  RESPONSE=$(curl -s "$API_URL" -H "$AUTH_HEADER")
else
  RESPONSE=$(curl -s "$API_URL")
fi

# Check for errors
if echo "$RESPONSE" | grep -q '"error"'; then
  echo "API Error:"
  echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
  exit 1
fi

# Parse and display voices
python3 << EOF
import json
import sys

data = json.loads('''$RESPONSE''')
voices = data.get('voices', [])

language_filter = "$LANGUAGE_FILTER".lower()

# Group by language
by_language = {}
for voice in voices:
    for lang in voice['languageCodes']:
        if language_filter and language_filter not in lang.lower():
            continue
        if lang not in by_language:
            by_language[lang] = []
        by_language[lang].append({
            'name': voice['name'],
            'gender': voice['ssmlGender'],
            'rate': voice.get('naturalSampleRateHertz', 'N/A')
        })

# Sort and display
for lang in sorted(by_language.keys()):
    print(f"\n{lang}:")
    print("-" * 50)
    for v in sorted(by_language[lang], key=lambda x: x['name']):
        # Highlight Neural2 and Studio voices (highest quality)
        quality = ""
        if "Neural2" in v['name']:
            quality = "⭐ Neural2"
        elif "Studio" in v['name']:
            quality = "⭐⭐ Studio"
        elif "Wavenet" in v['name']:
            quality = "Wavenet"
        elif "Standard" in v['name']:
            quality = "Standard"
        elif "Journey" in v['name']:
            quality = "⭐⭐ Journey"
        elif "Polyglot" in v['name']:
            quality = "Polyglot"
        print(f"  {v['name']:40} {v['gender']:8} {quality}")

print(f"\nTotal: {sum(len(v) for v in by_language.values())} voices in {len(by_language)} languages")
print("\n⭐⭐ = Highest quality (Studio/Journey)")
print("⭐  = High quality (Neural2)")
EOF
