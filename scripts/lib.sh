#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/opt/gym/devops/state"
LOCK_FILE="${STATE_DIR}/deploy.lock"
ACTIVE_SLOT_FILE="${STATE_DIR}/active_slot"
RELEASES_FILE="${STATE_DIR}/releases.env"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

error() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2
}

acquire_lock() {
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        error "Another deployment is currently in progress. Exiting."
        exit 75
    fi
}

get_active_slot() {
    if [[ -f "${ACTIVE_SLOT_FILE}" ]]; then
        cat "${ACTIVE_SLOT_FILE}"
    else
        echo "blue"
    fi
}

get_idle_slot() {
    local active
    active=$(get_active_slot)
    if [[ "${active}" == "blue" ]]; then
        echo "green"
    else
        echo "blue"
    fi
}

get_slot_be_port() {
    local slot="$1"
    if [[ "${slot}" == "blue" ]]; then
        echo "8101"
    else
        echo "8102"
    fi
}

get_slot_fe_port() {
    local slot="$1"
    if [[ "${slot}" == "blue" ]]; then
        echo "8201"
    else
        echo "8202"
    fi
}
