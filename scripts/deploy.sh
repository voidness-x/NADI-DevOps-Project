#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

acquire_lock

# Force working directory to deployment root so Docker Compose can access '.'
cd /opt/gym/devops

if [[ -f "/etc/gym/deploy.env" ]]; then
    source "/etc/gym/deploy.env"
fi
DRAIN_SECONDS="${DRAIN_SECONDS:-30}"

BACKEND_TAG="${1:-latest}"
FRONTEND_TAG="${2:-latest}"

ACTIVE_SLOT=$(get_active_slot)
IDLE_SLOT=$(get_idle_slot)
BE_PORT=$(get_slot_be_port "${IDLE_SLOT}")
FE_PORT=$(get_slot_fe_port "${IDLE_SLOT}")

log "=== Starting Deployment ==="
log "Active slot: ${ACTIVE_SLOT} | Target idle slot: ${IDLE_SLOT}"
log "Deploying Backend Tag: ${BACKEND_TAG} | Frontend Tag: ${FRONTEND_TAG}"

POSTGRES_PASSWORD=$(cat /etc/gym/secrets/postgres_password)

export SLOT="${IDLE_SLOT}"
export BE_PORT="${BE_PORT}"
export FE_PORT="${FE_PORT}"
export BACKEND_TAG="${BACKEND_TAG}"
export FRONTEND_TAG="${FRONTEND_TAG}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD}"

COMPOSE_FILE="/opt/gym/devops/compose/compose.slot.yml"

log "Building container images for ${IDLE_SLOT} slot..."
docker build -t "gym/backend:${BACKEND_TAG}" /opt/gym/src/backend

log "Launching containers on ${IDLE_SLOT} slot (Ports: BE=${BE_PORT}, FE=${FE_PORT})..."
docker compose -f "${COMPOSE_FILE}" up -d --remove-orphans

log "Executing smoke tests on ${IDLE_SLOT} slot..."
if ! "${SCRIPT_DIR}/smoke.sh" "${IDLE_SLOT}"; then
    error "Smoke test failed on ${IDLE_SLOT} slot! Tearing down candidate slot..."
    docker compose -f "${COMPOSE_FILE}" down
    exit 1
fi

log "Smoke tests passed. Switching traffic to ${IDLE_SLOT} slot..."
if "${SCRIPT_DIR}/switch.sh" "${IDLE_SLOT}"; then
    if [[ -f "${RELEASES_FILE}" ]]; then
        cp "${RELEASES_FILE}" "${STATE_DIR}/releases.prev.env"
    fi
    echo "BACKEND_TAG=${BACKEND_TAG}" > "${RELEASES_FILE}"
    echo "FRONTEND_TAG=${FRONTEND_TAG}" >> "${RELEASES_FILE}"
    
    log "Deployment to ${IDLE_SLOT} succeeded."
    
    log "Draining old slot (${ACTIVE_SLOT}) for ${DRAIN_SECONDS} seconds..."
    sleep "${DRAIN_SECONDS}"
    
    OLD_BE_PORT=$(get_slot_be_port "${ACTIVE_SLOT}")
    OLD_FE_PORT=$(get_slot_fe_port "${ACTIVE_SLOT}")
    
    log "Stopping old slot (${ACTIVE_SLOT}) containers..."
    SLOT="${ACTIVE_SLOT}" BE_PORT="${OLD_BE_PORT}" FE_PORT="${OLD_FE_PORT}" \
    BACKEND_TAG="${BACKEND_TAG}" FRONTEND_TAG="${FRONTEND_TAG}" POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    docker compose -f "${COMPOSE_FILE}" down
    
    log "=== Deployment Finished Successfully ==="
else
    error "Traffic switch failed! Tearing down ${IDLE_SLOT} slot..."
    docker compose -f "${COMPOSE_FILE}" down
    exit 1
fi
