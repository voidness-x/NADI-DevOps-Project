#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

acquire_lock

PREV_RELEASES_FILE="${STATE_DIR}/releases.prev.env"

if [[ ! -f "${PREV_RELEASES_FILE}" ]]; then
    error "No previous release file found at ${PREV_RELEASES_FILE}. Cannot perform automatic rollback."
    exit 1
fi

log "=== Starting Instant Rollback ==="
source "${PREV_RELEASES_FILE}"

ACTIVE_SLOT=$(get_active_slot)
IDLE_SLOT=$(get_idle_slot)
BE_PORT=$(get_slot_be_port "${IDLE_SLOT}")
FE_PORT=$(get_slot_fe_port "${IDLE_SLOT}")

log "Active slot: ${ACTIVE_SLOT} | Rolling back to idle slot: ${IDLE_SLOT}"
log "Reverting to Backend Tag: ${BACKEND_TAG} | Frontend Tag: ${FRONTEND_TAG}"

POSTGRES_PASSWORD=$(cat /etc/gym/secrets/postgres_password)

export SLOT="${IDLE_SLOT}"
export BE_PORT="${BE_PORT}"
export FE_PORT="${FE_PORT}"
export BACKEND_TAG="${BACKEND_TAG}"
export FRONTEND_TAG="${FRONTEND_TAG}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"

COMPOSE_FILE="/opt/gym/devops/compose/compose.slot.yml"

log "Starting previous container release on ${IDLE_SLOT} slot..."
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

log "Running smoke test on restored slot ${IDLE_SLOT}..."
if ! "${SCRIPT_DIR}/smoke.sh" "${IDLE_SLOT}"; then
    error "Smoke test failed on restored slot ${IDLE_SLOT}! Aborting rollback."
    docker compose -f "${COMPOSE_FILE}" down
    exit 1
fi

log "Reverting Caddy traffic to ${IDLE_SLOT} slot..."
if "${SCRIPT_DIR}/switch.sh" "${IDLE_SLOT}"; then
    cp "${PREV_RELEASES_FILE}" "${STATE_DIR}/releases.env"
    log "Rollback completed successfully. Traffic restored to ${IDLE_SLOT}."
    
    OLD_BE_PORT=$(get_slot_be_port "${ACTIVE_SLOT}")
    OLD_FE_PORT=$(get_slot_fe_port "${ACTIVE_SLOT}")
    
    SLOT="${ACTIVE_SLOT}" BE_PORT="${OLD_BE_PORT}" FE_PORT="${OLD_FE_PORT}" \
    BACKEND_TAG="${BACKEND_TAG}" FRONTEND_TAG="${FRONTEND_TAG}" POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    docker compose -f "${COMPOSE_FILE}" down
else
    error "Traffic switch failed during rollback!"
    exit 1
fi
