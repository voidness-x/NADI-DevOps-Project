#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TARGET_SLOT="${1:-}"

if [[ -z "${TARGET_SLOT}" || ( "${TARGET_SLOT}" != "blue" && "${TARGET_SLOT}" != "green" ) ]]; then
    error "Usage: $0 <blue|green>"
    exit 1
fi

CADDY_SLOTS_DIR="/etc/caddy/slots"
ACTIVE_LINK="${CADDY_SLOTS_DIR}/active.caddy"
TARGET_FILE="${CADDY_SLOTS_DIR}/${TARGET_SLOT}.caddy"

if [[ ! -f "${TARGET_FILE}" ]]; then
    error "Target slot file ${TARGET_FILE} does not exist."
    exit 1
fi

log "Swapping active Caddy slot symlink to ${TARGET_SLOT}.caddy..."
ln -sfn "${TARGET_SLOT}.caddy" "${ACTIVE_LINK}"

log "Reloading Caddy web server..."
if sudo /usr/bin/systemctl reload caddy; then
    echo "${TARGET_SLOT}" > "${STATE_DIR}/active_slot"
    log "Traffic successfully switched to ${TARGET_SLOT} slot."
else
    error "Caddy reload failed! Reverting symlink..."
    PREV_SLOT="blue"
    [[ "${TARGET_SLOT}" == "blue" ]] && PREV_SLOT="green"
    ln -sfn "${PREV_SLOT}.caddy" "${ACTIVE_LINK}"
    sudo /usr/bin/systemctl reload caddy || true
    exit 1
fi
