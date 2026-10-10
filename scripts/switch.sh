#!/usr/bin/env bash
set -euo pipefail

TARGET_SLOT="${1:-green}"
SLOTS_DIR="/etc/caddy/slots"
STATE_DIR="/opt/gym/state"

SLOT_FILE="${SLOTS_DIR}/${TARGET_SLOT}.caddy"
ACTIVE_LINK="${SLOTS_DIR}/active.caddy"

if [ ! -f "$SLOT_FILE" ]; then
  echo "ERROR: Target slot file $SLOT_FILE does not exist!"
  exit 1
fi

echo "Swapping active Caddy slot symlink to ${TARGET_SLOT}.caddy..."
ln -sfn "${TARGET_SLOT}.caddy" "$ACTIVE_LINK"

mkdir -p "$STATE_DIR"
echo "$TARGET_SLOT" > "$STATE_DIR/active_slot"

echo "Reloading Caddy web server..."
caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

echo "SUCCESS: Ingress switched to ${TARGET_SLOT}."
