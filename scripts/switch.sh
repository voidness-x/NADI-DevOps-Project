#!/usr/bin/env bash
set -euo pipefail

TARGET_SLOT="${1:-green}"
SLOT_FILE="/etc/caddy/slots/${TARGET_SLOT}.caddy"
ACTIVE_LINK="/etc/caddy/slots/active.caddy"
STATE_FILE="/opt/gym/state/active_slot"

if [ ! -f "$SLOT_FILE" ]; then
  echo "ERROR: Target slot file $SLOT_FILE does not exist!" >&2
  exit 1
fi

# 1. Atomically swap Caddy slot symlink
ln -sfn "$SLOT_FILE" "$ACTIVE_LINK"

# 2. Update state file
mkdir -p /opt/gym/state
echo "$TARGET_SLOT" > "$STATE_FILE"
chown deploy:deploy "$STATE_FILE" 2>/dev/null || true

# 3. Signal Caddy to reload in-memory without dropping active connections
if command -v caddy &>/dev/null; then
  caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null || systemctl reload caddy
else
  systemctl reload caddy
fi

echo "Ingress switched to ${TARGET_SLOT} successfully with zero downtime."
