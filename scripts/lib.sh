#!/usr/bin/env bash
set -euo pipefail

LOCK_FILE="/opt/gym/devops/state/deploy.lock"
SLOT_FILE="/opt/gym/devops/state/active_slot"

acquire_lock() {
    exec 200>"${LOCK_FILE}"
    flock -n 200 || { echo "Deployment lock active. Skipping."; exit 1; }
}

release_lock() {
    flock -u 200 || true
}

get_active_slot() {
    if [[ -f "${SLOT_FILE}" ]]; then
        cat "${SLOT_FILE}"
    else
        echo "blue"
    fi
}

get_candidate_slot() {
    local active="$1"
    if [[ "${active}" == "blue" ]]; then
        echo "green"
    else
        echo "blue"
    fi
}

get_slot_port() {
    local slot="$1"
    if [[ "${slot}" == "blue" ]]; then
        echo "8001"
    else
        echo "8002"
    fi
}
