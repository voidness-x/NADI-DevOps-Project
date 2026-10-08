#!/usr/bin/env bash
set -euo pipefail

# Always execute from the devops root directory to avoid working directory permission issues
cd /opt/gym/devops

SCRIPT_DIR="/opt/gym/devops/scripts"
source "${SCRIPT_DIR}/lib.sh"

acquire_lock

echo "=== Starting Blue/Green Deployment ==="

# 1. Pre-deployment Database Snapshot
if docker ps --format "{{.Names}}" | grep -q "gym-postgres"; then
    echo "Creating pre-deployment database backup..."
    BACKUP_FILE="/var/backups/gym/gym_db_$(date +%Y%m%d_%H%M%S).sql"
    docker exec gym-postgres pg_dump -U gym_user gym_db > "${BACKUP_FILE}" || {
        echo "Database backup failed! Aborting deployment."
        release_lock
        exit 1
    }
    echo "Backup saved to ${BACKUP_FILE}"
fi

# 2. Determine Current Active & Candidate Slots
ACTIVE_SLOT=$(get_active_slot)
CANDIDATE_SLOT=$(get_candidate_slot "${ACTIVE_SLOT}")

echo "Active Slot: ${ACTIVE_SLOT}"
echo "Target Candidate Slot: ${CANDIDATE_SLOT}"

# 3. Export Environment Variables for Candidate Slot
export SLOT="${CANDIDATE_SLOT}"
export BE_PORT=$(get_slot_port "${CANDIDATE_SLOT}")
export BACKEND_TAG="${1:-latest}"

# Load secrets if present
if [[ -f /etc/gym/secrets/db.env ]]; then
    set -o allexport
    source /etc/gym/secrets/db.env
    set +o allexport
fi

# 4. Spin up Candidate Slot
echo "Deploying candidate slot (${CANDIDATE_SLOT}) on port ${BE_PORT} with image tag ${BACKEND_TAG}..."
docker compose -f /opt/gym/devops/compose/compose.slot.yml up -d --build || {
    echo "Container startup failed! Executing rollback..."
    "${SCRIPT_DIR}/rollback.sh" "${CANDIDATE_SLOT}"
    release_lock
    exit 1
}

# 5. Execute Health / Smoke Tests
if ! "${SCRIPT_DIR}/smoke.sh" "127.0.0.1" "${BE_PORT}"; then
    echo "Smoke test failed on slot ${CANDIDATE_SLOT}! Executing rollback..."
    "${SCRIPT_DIR}/rollback.sh" "${CANDIDATE_SLOT}"
    release_lock
    exit 1
fi

# 6. Switch Ingress Traffic & Decommission Old Slot
"${SCRIPT_DIR}/switch.sh" "${CANDIDATE_SLOT}"
echo "Stopping inactive slot (${ACTIVE_SLOT})..."
export SLOT="${ACTIVE_SLOT}"
docker compose -f /opt/gym/devops/compose/compose.slot.yml down

echo "=== Deployment Successfully Completed ==="
release_lock
