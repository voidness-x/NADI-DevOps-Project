#!/usr/bin/env bash
set -euo pipefail
source /opt/gym/devops/scripts/lib.sh

if [ -f "/etc/gym/backend.env" ]; then
  set -a; source /etc/gym/backend.env; set +a
fi

CURRENT_SLOT=$(read_active_slot)
FAILED_SLOT="${1:-$(other_slot "$CURRENT_SLOT")}"
slot_ports "$FAILED_SLOT"

export SLOT="$FAILED_SLOT"
export BE_PORT="$BE_PORT"
export FE_PORT="$FE_PORT"

echo "=== Executing Rollback ==="
echo "Tearing down failed candidate slot ($FAILED_SLOT)..."

docker compose -p "gym-$FAILED_SLOT" -f "$COMPOSE_DIR/compose.slot.yml" down --remove-orphans || true

echo "Rollback completed. Active slot unchanged ($CURRENT_SLOT)."
