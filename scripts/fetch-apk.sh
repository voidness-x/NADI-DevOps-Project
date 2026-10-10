#!/usr/bin/env bash
set -Eeuo pipefail

TAG="${1:-}"
[[ $TAG =~ ^v[0-9]+.[0-9]+.[0-9]+.*$ ]] || { echo "usage: fetch-apk.sh vX.Y.Z" >&2; exit 2; }

if [ -f /etc/gym/fetch-apk.env ]; then
  source /etc/gym/fetch-apk.env
fi

GITHUB_REPO="${GITHUB_REPO:-Techies-Lab-Projects-01-Nadi/Nadi-Flutter}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
APK_DIR="/srv/apk"
REL_DIR="$APK_DIR/releases"
KEEP=3

mkdir -p "$REL_DIR"
VERSION="${TAG#v}"
NAME="gym-${VERSION}.apk"

echo "=== Fetching Mobile APK for ${TAG} from ${GITHUB_REPO} ==="

AUTH_HEADER=()
if [ -n "$GITHUB_TOKEN" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

# 1. Fetch Release Metadata from GitHub REST API
RELEASE_JSON=$(curl -fsS "${AUTH_HEADER[@]}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/${TAG}")

# 2. Extract APK asset API URL and filename
ASSET_API_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[]? | select(.name | endswith(".apk")) | .url' | head -n 1)
ASSET_NAME=$(echo "$RELEASE_JSON" | jq -r '.assets[]? | select(.name | endswith(".apk")) | .name' | head -n 1)

if [ -z "$ASSET_API_URL" ] || [ "$ASSET_API_URL" = "null" ]; then
  echo "ERROR: No .apk asset found in release ${TAG} for ${GITHUB_REPO}" >&2
  exit 1
fi

echo "Found release asset: ${ASSET_NAME}"
echo "Downloading 51.2MB APK binary via GitHub Asset API..."

TMP_FILE=$(mktemp "$REL_DIR/.download.XXXXXX")

# For private repositories, streaming the binary requires Accept: application/octet-stream
curl -fsSL "${AUTH_HEADER[@]}" \
  -H "Accept: application/octet-stream" \
  -o "$TMP_FILE" \
  "$ASSET_API_URL"

# Move verified binary into releases directory
mv -f "$TMP_FILE" "$REL_DIR/$NAME"
chmod 644 "$REL_DIR/$NAME"

# Atomically link latest.apk to the newly downloaded binary
ln -sfn "releases/$NAME" "$APK_DIR/latest.apk"

# Compute actual size and sha256 checksum
SHA_VAL=$(sha256sum "$REL_DIR/$NAME" | awk '{print $1}')
SIZE_VAL=$(stat -c %s "$REL_DIR/$NAME")

# Generate version.json
cat << JSON > "$APK_DIR/version.json"
{
  "version": "${VERSION}",
  "tag": "${TAG}",
  "file": "latest.apk",
  "sha256": "${SHA_VAL}",
  "size_bytes": ${SIZE_VAL},
  "published_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

chmod 644 "$APK_DIR/version.json"
echo "SUCCESS: Downloaded ${NAME} (${SIZE_VAL} bytes, SHA-256: ${SHA_VAL})!"
