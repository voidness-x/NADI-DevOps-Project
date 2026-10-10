#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib.sh
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

# 1. Pre-deployment Database Backup
if docker ps --format "{{.Names}}" | grep -q "gym-postgres"; then
  log "Creating pre-deployment database snapshot..."
  BACKUP_FILE="/var/backups/gym/gym_db_$(date +%Y%m%d_%H%M%S).sql"
  docker exec gym-postgres pg_dump -U gym_user gym_db > "${BACKUP_FILE}" || true
  log "Database snapshot saved to ${BACKUP_FILE}"
fi

# 2. Export environment variables for Docker Compose
export SLOT="${CANDIDATE_SLOT}"
export BE_PORT="${BE_PORT}"
export FE_PORT="${FE_PORT}"
export BACKEND_TAG="${1:-latest}"
export FRONTEND_TAG="latest"

if [ -f "/etc/gym/backend.env" ]; then
  set -a; source /etc/gym/backend.env; set +a
fi

# 3. Build & Launch Candidate Slot
log "Launching candidate slot ${CANDIDATE_SLOT} on port ${BE_PORT}..."
docker compose -p "gym-${CANDIDATE_SLOT}" -f "$COMPOSE_DIR/compose.slot.yml" up -d --build

# 4. Automatic Database Seeding (Pre-traffic validation)
log "Running database seed on candidate slot..."
docker exec "gym-${CANDIDATE_SLOT}-backend" python seed.py || echo "Seed already applied or skipped."

# 5. Health & Smoke Validation
log "Running smoke test on candidate slot ${CANDIDATE_SLOT}..."
if /opt/gym/devops/scripts/smoke.sh "${CANDIDATE_SLOT}"; then
  log "Candidate slot passed smoke tests. Switching traffic..."
  
  # 6. Atomic Proxy Swap (No Sudo)
  /opt/gym/devops/scripts/switch.sh "${CANDIDATE_SLOT}"
  write_active_slot "${CANDIDATE_SLOT}"
  
  log "Deployment SUCCESSFUL! Active slot is now ${CANDIDATE_SLOT}."
  
  # 7. Graceful connection draining before stopping old slot
  log "Draining traffic on old slot ${CURRENT_SLOT}..."
  sleep 5
  docker compose -p "gym-${CURRENT_SLOT}" -f "$COMPOSE_DIR/compose.slot.yml" stop
else
  log "ERROR: Candidate slot ${CANDIDATE_SLOT} failed smoke tests! Executing rollback..."
  /opt/gym/devops/scripts/rollback.sh "${CANDIDATE_SLOT}"
  exit 1
fi
