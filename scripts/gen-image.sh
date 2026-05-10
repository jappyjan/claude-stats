#!/bin/bash
# Generate an image via Google Gemini 2.5 Flash Image (Nano Banana).
# Usage: ./gen-image.sh "<prompt>" <output-png-path>
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 \"<prompt>\" <output-png-path> [aspect-ratio]" >&2
    echo "  aspect-ratio: one of 1:1 3:2 2:3 3:4 4:3 4:5 5:4 9:16 16:9 21:9 (default 1:1)" >&2
    exit 1
fi

PROMPT="$1"
OUT="$2"
ASPECT="${3:-1:1}"

if [ -z "${GEMINI_API_KEY:-}" ]; then
    echo "GEMINI_API_KEY not set" >&2
    exit 1
fi

TMP="$(mktemp -t gemini-img.XXXXXX.json)"
trap 'rm -f "$TMP"' EXIT

# Build request JSON safely with python (handles quoting/escaping).
REQ="$(python3 -c '
import json, sys
prompt, aspect = sys.argv[1], sys.argv[2]
print(json.dumps({
    "contents": [{"parts": [{"text": prompt}]}],
    "generationConfig": {"imageConfig": {"aspectRatio": aspect}}
}))
' "$PROMPT" "$ASPECT")"

curl -sS \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$REQ" \
    -o "$TMP"

# Extract first inline_data.data (base64) and decode to PNG.
python3 - <<EOF
import base64, json, sys
with open("$TMP") as f:
    data = json.load(f)
candidates = data.get("candidates", [])
if not candidates:
    print("No candidates returned. Full response:", file=sys.stderr)
    print(json.dumps(data, indent=2)[:2000], file=sys.stderr)
    sys.exit(2)
parts = candidates[0].get("content", {}).get("parts", [])
for p in parts:
    inline = p.get("inline_data") or p.get("inlineData")
    if inline and "data" in inline:
        with open("$OUT", "wb") as out:
            out.write(base64.b64decode(inline["data"]))
        print("Wrote $OUT")
        sys.exit(0)
# Fallback: dump text + bail
texts = [p.get("text", "") for p in parts]
print("No image in response. Texts:", texts[:2], file=sys.stderr)
sys.exit(3)
EOF
