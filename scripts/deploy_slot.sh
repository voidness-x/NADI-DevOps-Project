#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/opt/gym/state/active_slot"
CURRENT_SLOT=$(cat "$STATE_FILE" 2>/dev/null || echo "blue")

if [ "$CURRENT_SLOT" = "green" ]; then
    CANDIDATE_SLOT="blue"
    CANDIDATE_BE_PORT="8101"
    CANDIDATE_FE_PORT="8201"
    PREV_BE_PORT="8102"
    PREV_FE_PORT="8202"
else
    CANDIDATE_SLOT="green"
    CANDIDATE_BE_PORT="8102"
    CANDIDATE_FE_PORT="8202"
    PREV_BE_PORT="8101"
    PREV_FE_PORT="8201"
fi

echo "=== Starting Zero-Downtime Deployment ==="
echo "Active Slot: ${CURRENT_SLOT} | Target Candidate Slot: ${CANDIDATE_SLOT}"

# 1. Pull latest repository changes
cd /opt/gym/devops
git pull origin main
git -C /opt/gym/src/frontend pull origin main || true

# 2. Source environment variables
if [ -f "/etc/gym/backend.env" ]; then
    set -a
    source /etc/gym/backend.env
    set +a
fi

export SLOT="${CANDIDATE_SLOT}"
export BE_PORT="${CANDIDATE_BE_PORT}"
export FE_PORT="${CANDIDATE_FE_PORT}"
export BACKEND_TAG="${BACKEND_TAG:-latest}"
export FRONTEND_TAG="${FRONTEND_TAG:-latest}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
if [ -z "$POSTGRES_PASSWORD" ] && [ -f "/etc/gym/secrets/postgres_password" ]; then
    export POSTGRES_PASSWORD="$(cat /etc/gym/secrets/postgres_password)"
fi

# 3. Build and launch candidate slot containers (Backend & Frontend)
docker compose -f compose/compose.slot.yml build
docker compose -f compose/compose.slot.yml up -d --no-deps

# 4. Database Seeding Check
echo "Executing automated database seeding on ${CANDIDATE_SLOT} slot..."
docker exec "gym-${CANDIDATE_SLOT}-backend" python seed.py || true

# 5. Perform health smoke testing
if /opt/gym/devops/scripts/smoke.sh "$CANDIDATE_SLOT"; then
    echo "Candidate slot ${CANDIDATE_SLOT} passed health checks. Executing proxy swap..."
    
    # 6. Symlink update & zero-sudo Caddy reload
    ln -sfn "/etc/caddy/slots/${CANDIDATE_SLOT}.caddy" /etc/caddy/slots/active.caddy
    caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    
    # 7. Persist active slot state
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$CANDIDATE_SLOT" > "$STATE_FILE"
    echo "Deployment successful! Active slot is now ${CANDIDATE_SLOT}."
    
    # 8. Stop previous slot containers
    sleep 5
    SLOT="${CURRENT_SLOT}" BE_PORT="${PREV_BE_PORT}" FE_PORT="${PREV_FE_PORT}" \
    docker compose -f compose/compose.slot.yml stop
else
    echo "ERROR: Candidate slot ${CANDIDATE_SLOT} failed smoke tests. Aborting slot swap!"
    SLOT="${CANDIDATE_SLOT}" BE_PORT="${CANDIDATE_BE_PORT}" FE_PORT="${CANDIDATE_FE_PORT}" \
    docker compose -f compose/compose.slot.yml stop
    exit 1
fi
