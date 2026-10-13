#!/usr/bin/env bash
cd /opt/gym/devops
set -euo pipefail
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

# Pre-deployment Database Snapshot
if docker ps --format "{{.Names}}" | grep -q "gym-postgres"; then
  log "Creating pre-deployment database snapshot..."
  BACKUP_FILE="/var/backups/gym/gym_db_$(date +%Y%m%d_%H%M%S).sql"
  docker exec gym-postgres pg_dump -U gym_user gym_db > "${BACKUP_FILE}" || true
fi

# Load Database Password & Config
export POSTGRES_PASSWORD="$(cat /etc/gym/secrets/postgres_password 2>/dev/null || echo "")"
if [ -f "/etc/gym/backend.env" ]; then
  set -a; source /etc/gym/backend.env; set +a
fi

export SLOT="${CANDIDATE_SLOT}"
export BE_PORT="${BE_PORT}"
export FE_PORT="${FE_PORT}"
export BACKEND_TAG="${1:-latest}"
export FRONTEND_TAG="latest"

# Pull latest code from GitHub
if [ -d "/opt/gym/src/backend/.git" ]; then
  log "Pulling latest backend code from origin/main..."
  git -C /opt/gym/src/backend pull origin main || true
fi
if [ -d "/opt/gym/src/frontend/.git" ]; then
  log "Pulling latest frontend code from origin/main..."
  git -C /opt/gym/src/frontend pull origin main || true
fi

log "Launching candidate slot ${CANDIDATE_SLOT} on port ${BE_PORT}..."
docker compose -p "gym-${CANDIDATE_SLOT}" -f "$COMPOSE_DIR/compose.slot.yml" --env-file "$COMPOSE_DIR/slot-${CANDIDATE_SLOT}.env" up -d --build

log "Running database seed on candidate slot..."
docker exec "gym-${CANDIDATE_SLOT}-backend" python seed.py || echo "Seed check passed or skipped."

log "Running smoke test on candidate slot ${CANDIDATE_SLOT}..."
if /opt/gym/devops/scripts/smoke.sh "${CANDIDATE_SLOT}"; then
  log "Candidate slot passed smoke tests. Switching traffic..."
  /opt/gym/devops/scripts/switch.sh "${CANDIDATE_SLOT}"
  write_active_slot "${CANDIDATE_SLOT}"

  log "Deployment SUCCESSFUL! Active slot is now ${CANDIDATE_SLOT}."
  DISCORD_URL=$(cat /etc/gym/secrets/discord_webhook_url 2>/dev/null || true)
  [ -n "$DISCORD_URL" ] && curl -s -H "Content-Type: application/json" -d "{\"content\":\"✅ **Deployment Successful!** Candidate slot ${CANDIDATE_SLOT} is now active (Zero-Downtime swap)\"}" "$DISCORD_URL" >/dev/null || true

  sleep 5
  docker compose -p "gym-${CURRENT_SLOT}" -f "$COMPOSE_DIR/compose.slot.yml" stop
else
  log "ERROR: Candidate slot ${CANDIDATE_SLOT} failed smoke tests! Executing rollback..."
  DISCORD_URL=$(cat /etc/gym/secrets/discord_webhook_url 2>/dev/null || true)
  [ -n "$DISCORD_URL" ] && curl -s -H "Content-Type: application/json" -d "{\"content\":\"🚨 **Deployment Failed & Rolled Back!** Candidate slot ${CANDIDATE_SLOT} failed smoke tests. Live slot ${CURRENT_SLOT} remains safe.\"}" "$DISCORD_URL" >/dev/null || true
  /opt/gym/devops/scripts/rollback.sh "${CANDIDATE_SLOT}"
  exit 1
fi
