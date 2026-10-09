#!/usr/bin/env bash
set -euo pipefail

STATE_FILE="/opt/gym/state/active_slot"
CURRENT_SLOT=$(cat "$STATE_FILE" 2>/dev/null || echo "blue")

if [ "$CURRENT_SLOT" = "green" ]; then
    CANDIDATE_SLOT="blue"
    CANDIDATE_PORT="8101"
    PREV_PORT="8102"
else
    CANDIDATE_SLOT="green"
    CANDIDATE_PORT="8102"
    PREV_PORT="8101"
fi

echo "=== Starting Zero-Downtime Deployment ==="
echo "Active Slot: ${CURRENT_SLOT} | Target Candidate Slot: ${CANDIDATE_SLOT}"

# 1. Pull latest repository changes
cd /opt/gym/devops
git pull origin main

# 2. Source environment variables if present
if [ -f "/etc/gym/backend.env" ]; then
    set -a
    source /etc/gym/backend.env
    set +a
fi

if [ -f "/opt/gym/devops/.env" ]; then
    set -a
    source /opt/gym/devops/.env
    set +a
fi

export SLOT="${CANDIDATE_SLOT}"
export BE_PORT="${CANDIDATE_PORT}"
export BACKEND_TAG="${BACKEND_TAG:-latest}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-REPLACE_WITH_POSTGRES_PASSWORD}"

# 3. Build and launch candidate container
docker compose -f compose/compose.slot.yml build
docker compose -f compose/compose.slot.yml up -d --no-deps

# 4. Automatic Database Seeding (Pre-traffic validation)
echo "Executing automated database seeding on ${CANDIDATE_SLOT} slot..."
if docker exec "gym-${CANDIDATE_SLOT}-backend" python seed.py; then
    echo "Database seed check passed on ${CANDIDATE_SLOT} slot."
else
    echo "WARNING: Seed execution returned non-zero exit code on ${CANDIDATE_SLOT} slot."
fi

# 5. Perform automated health smoke testing
if /opt/gym/devops/scripts/smoke.sh "$CANDIDATE_SLOT"; then
    echo "Candidate slot ${CANDIDATE_SLOT} passed health checks. Executing dynamic proxy swap..."
    
    # 6. Atomic symlink update (NO SUDO)
    ln -sfn "/etc/caddy/slots/${CANDIDATE_SLOT}.caddy" /etc/caddy/slots/active.caddy
    
    # 7. Reload Caddy config via Admin API on port 2019 (NO SUDO)
    caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    
    # 8. Persist active slot state
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$CANDIDATE_SLOT" > "$STATE_FILE"
    echo "Deployment successful! Active slot is now ${CANDIDATE_SLOT}."
    
    # 9. Stop previous slot container after grace period
    sleep 5
    SLOT="${CURRENT_SLOT}" BE_PORT="${PREV_PORT}" docker compose -f compose/compose.slot.yml stop
else
    echo "ERROR: Candidate slot ${CANDIDATE_SLOT} failed smoke tests. Aborting slot swap!"
    SLOT="${CANDIDATE_SLOT}" BE_PORT="${CANDIDATE_PORT}" docker compose -f compose/compose.slot.yml stop
    exit 1
fi
