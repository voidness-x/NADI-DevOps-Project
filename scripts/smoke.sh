#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

SLOT="${1:-}"

if [[ -z "${SLOT}" ]]; then
    error "Usage: $0 <blue|green>"
    exit 1
fi

BE_PORT=$(get_slot_be_port "${SLOT}")
LOG_FILE="${STATE_DIR}/smoke-${SLOT}.log"

log "Executing smoke tests against ${SLOT} slot (Backend Port: ${BE_PORT})..."

MAX_RETRIES=10
RETRY_COUNT=0
HEALTH_OK=false

while [[ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]]; do
    if curl -fsS "http://127.0.0.1:${BE_PORT}/docs" > /dev/null 2>&1; then
        HEALTH_OK=true
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    sleep 2
done

if [[ "${HEALTH_OK}" == "true" ]]; then
    log "Smoke tests PASSED for ${SLOT} slot."
    exit 0
else
    error "Smoke tests FAILED for ${SLOT} slot on http://127.0.0.1:${BE_PORT}/docs."
    exit 1
fi
