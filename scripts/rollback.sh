#!/usr/bin/env bash
set -euo pipefail

CANDIDATE_SLOT="${1:-green}"

echo "=== Executing Rollback ==="
echo "Tearing down failed candidate slot (${CANDIDATE_SLOT})..."

export SLOT="${CANDIDATE_SLOT}"
docker compose -f /opt/gym/devops/compose/compose.slot.yml down || true

echo "Rollback completed. Active slot unchanged."
