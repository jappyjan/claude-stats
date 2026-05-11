#!/bin/bash
set -euo pipefail

# Generates a Sparkle appcast.xml from a list of GitHub releases (stdin JSON)
# plus the EdDSA signature of the current release's ZIP (env vars).
#
# Usage:
#   SPARKLE_SIGNATURE='abc...=' SPARKLE_LENGTH=3000000 \
#       ./scripts/make-appcast.sh < releases.json > appcast.xml
#
# stdin: the response body of `gh api repos/<owner>/<repo>/releases`
#        (a JSON array sorted newest-first by GitHub's API).
# env SPARKLE_SIGNATURE: EdDSA signature of ClaudeStats.zip, base64 (no XML
#        attribute syntax — just the bare value).
# env SPARKLE_LENGTH: byte size of ClaudeStats.zip.
#
# Output: appcast.xml on stdout, with exactly one <item> — the newest
#         release that has a ClaudeStats.zip asset. Older releases are
#         filtered because we don't keep their EdDSA signatures around.

: "${SPARKLE_SIGNATURE:?must be set}"
: "${SPARKLE_LENGTH:?must be set}"

JSON="$(cat)"

# Pick the newest release whose asset list contains ClaudeStats.zip.
# `jq -e` exits non-zero if no such release exists.
RELEASE="$(echo "$JSON" | jq -e '
    [.[] | select(.assets[].name == "ClaudeStats.zip")] | .[0]
')"

TAG="$(echo "$RELEASE" | jq -r '.tag_name')"
VERSION="${TAG#v}"
NAME="$(echo "$RELEASE" | jq -r '.name')"
HTML_URL="$(echo "$RELEASE" | jq -r '.html_url')"
PUBLISHED="$(echo "$RELEASE" | jq -r '.published_at')"
ZIP_URL="$(echo "$RELEASE" | jq -r '.assets[] | select(.name == "ClaudeStats.zip") | .browser_download_url')"

cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ClaudeStats</title>
    <link>https://jappyjan.github.io/claude-stats/appcast.xml</link>
    <description>Most recent ClaudeStats release.</description>
    <language>en</language>
    <item>
      <title>${NAME}</title>
      <pubDate>${PUBLISHED}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${HTML_URL}</sparkle:releaseNotesLink>
      <enclosure url="${ZIP_URL}" sparkle:edSignature="${SPARKLE_SIGNATURE}" length="${SPARKLE_LENGTH}" type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
