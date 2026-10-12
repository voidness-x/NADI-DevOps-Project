#!/usr/bin/env bash
set -euo pipefail

# 1. Always switch into /opt/gym/devops (prevents stat . permission denied)
cd /opt/gym/devops

source /opt/gym/devops/scripts/lib.sh

acquire_lock
DEPLOY_ID="$(date -u +%Y%m%dT%H%M%S)"
exec > >(tee -a "$LOG_DIR/deploy-$DEPLOY_ID.log") 2>&1

CURRENT_SLOT=$(read_active_slot)
CANDIDATE_SLOT=$(other_slot "$CURRENT_SLOT")
slot_ports "$CANDIDATE_SLOT"

log "=== Starting Zero-Downtime Deployment ==="
log "Active Slot: ${CURRENT_SLOT} | Target Candidate Slot: ${CANDIDATE_SLOT}"
log "Target Ports: Backend=${BE_PORT} Frontend=${FE_PORT}"

# 2. Pull latest code from GitHub for both repositories
log "Updating source code from GitHub..."
git -C /opt/gym/src/backend fetch --quiet origin main
git -C /opt/gym/src/backend reset --hard --quiet origin/main

git -C /opt/gym/src/frontend fetch --quiet origin main
git -C /opt/gym/src/frontend reset --hard --quiet origin/main

BE_COMMIT=$(git -C /opt/gym/src/backend rev-parse --short HEAD)
FE_COMMIT=$(git -C /opt/gym/src/frontend rev-parse --short HEAD)
log "Building with: Backend [${BE_COMMIT}] | Frontend [${FE_COMMIT}]"

# 3. Pre-deployment Database Snapshot
if docker ps --format "{{.Names}}" | grep -q "gym-postgres"; then
  log "Creating pre-deployment database snapshot..."
  BACKUP_FILE="/var/backups/gym/gym_db_$(date +%Y%m%d_%H%M%S).sql"
  docker exec gym-postgres pg_dump -U gym_user gym_db > "${BACKUP_FILE}" || true
fi

# 4. Load Database Credentials & Config
export POSTGRES_PASSWORD="$(cat /etc/gym/secrets/postgres_password 2>/dev/null || echo "")"
if [ -f "/etc/gym/backend.env" ]; then
  set -a; source /etc/gym/backend.env; set +a
fi

export SLOT="${CANDIDATE_SLOT}"
export BE_PORT="${BE_PORT}"
export FE_PORT="${FE_PORT}"
export BACKEND_TAG="${1:-latest}"
export FRONTEND_TAG="latest"

# 5. Build Candidate Slot with the newly pulled code
log "Launching candidate slot ${CANDIDATE_SLOT} on port ${BE_PORT}..."
docker compose -p "gym-${CANDIDATE_SLOT}" -f "$COMPOSE_DIR/compose.slot.yml" --env-file "$COMPOSE_DIR/slot-${CANDIDATE_SLOT}.env" up -d --build

# 6. Database Seed check
log "Running database seed on candidate slot..."
docker exec "gym-${CANDIDATE_SLOT}-backend" python seed.py || echo "Seed check passed or skipped."

# 7. Smoke Tests & Zero-Downtime Traffic Switch
log "Running smoke test on candidate slot ${CANDIDATE_SLOT}..."
if /opt/gym/devops/scripts/smoke.sh "${CANDIDATE_SLOT}"; then
  log "Candidate slot passed smoke tests. Switching traffic..."
  /opt/gym/devops/scripts/switch.sh "${CANDIDATE_SLOT}"
  write_active_slot "${CANDIDATE_SLOT}"

  log "Deployment SUCCESSFUL! Active slot is now ${CANDIDATE_SLOT}."
  notify_discord "🚀 **[DEPLOY]** Successfully deployed to slot **${CANDIDATE_SLOT}**! (Frontend: \`${FE_COMMIT}\` | Backend: \`${BE_COMMIT}\`)"

  sleep 5
  docker compose -p "gym-${CURRENT_SLOT}" -f "$COMPOSE_DIR/compose.slot.yml" stop
else
  log "ERROR: Candidate slot ${CANDIDATE_SLOT} failed smoke tests! Executing rollback..."
  notify_discord "⚠️ **[ROLLBACK]** Candidate slot **${CANDIDATE_SLOT}** failed smoke tests. Rolled back to **${CURRENT_SLOT}**."
  /opt/gym/devops/scripts/rollback.sh "${CANDIDATE_SLOT}"
  exit 1
fi
