#!/usr/bin/env bash
set -Eeuo pipefail

TAG=${1:-}
[[ $TAG =~ ^v[0-9]+.[0-9]+.[0-9]+.*$ ]] || { echo "usage: fetch-apk.sh vX.Y.Z" >&2; exit 2; }

if [ -f /etc/gym/fetch-apk.env ]; then
  source /etc/gym/fetch-apk.env
fi

GITHUB_REPO=${GITHUB_REPO:-"Techies-Lab-Projects-01-Nadi/Nadi-Mobile"}
GITHUB_TOKEN=${GITHUB_TOKEN:-""}
APK_DIR="/srv/apk"
REL_DIR="$APK_DIR/releases"
KEEP=3

mkdir -p "$REL_DIR"
VERSION=${TAG#v}
NAME="gym-$VERSION.apk"

echo "=== Fetching Mobile APK for $TAG from $GITHUB_REPO ==="

# Build headers
AUTH_HEADER=""
if [ -n "$GITHUB_TOKEN" ]; then
  AUTH_HEADER="Authorization: Bearer $GITHUB_TOKEN"
fi

# Fetch Release Metadata from GitHub API
RELEASE_JSON=$(curl -fsS ${AUTH_HEADER:+-H "$AUTH_HEADER"}   -H "Accept: application/vnd.github+json"   "https://api.github.com/repos/$GITHUB_REPO/releases/tags/$TAG" 2>/dev/null || echo "{}")

# Find APK download URL or asset URL
APK_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[]? | select(.name | endswith(".apk")) | .browser_download_url' | head -n 1)

if [ -z "$APK_URL" ] || [ "$APK_URL" = "null" ]; then
  echo "Notice: No APK asset in GitHub release, checking repo downloads or generating release placeholder..."
  # If developer has not uploaded asset yet, generate manifest placeholder
  cat << JSON > "$APK_DIR/version.json"
{
  "version": "$VERSION",
  "tag": "$TAG",
  "status": "pending_upload",
  "file": "latest.apk",
  "published_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
  echo "Release metadata registered for $TAG."
  exit 0
fi

echo "Downloading APK asset: $APK_URL..."
TMP_FILE=$(mktemp "$REL_DIR/.download.XXXXXX")
curl -fsSL ${AUTH_HEADER:+-H "$AUTH_HEADER"} -o "$TMP_FILE" "$APK_URL"

# Move into place
mv -f "$TMP_FILE" "$REL_DIR/$NAME"
chmod 644 "$REL_DIR/$NAME"

# Update symlink to latest.apk
ln -sfn "releases/$NAME" "$APK_DIR/latest.apk"

# Compute SHA256
SHA_VAL=$(sha256sum "$REL_DIR/$NAME" | awk '{print $1}')
SIZE_VAL=$(stat -c %s "$REL_DIR/$NAME")

# Generate version.json
cat << JSON > "$APK_DIR/version.json"
{
  "version": "$VERSION",
  "tag": "$TAG",
  "file": "releases/$NAME",
  "sha256": "$SHA_VAL",
  "size_bytes": $SIZE_VAL,
  "published_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

chmod 644 "$APK_DIR/version.json"
echo "SUCCESS: APK $NAME published and version.json updated."
