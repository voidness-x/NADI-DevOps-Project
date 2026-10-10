#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BASE=/opt/gym
STATE=/opt/gym/state
DEVOPS=/opt/gym/devops
COMPOSE_DIR=/opt/gym/devops/compose
LOG_DIR=/var/log/gym
TEXTFILE_DIR=/var/lib/node_exporter/textfile
EX_BUSY=75

log() { printf '%s [%s] %s\n' "$(date -u +%FT%TZ)" "${DEPLOY_ID:-n/a}" "$*"; }

other_slot() {
  local cur
  cur=$(echo "$1" | tr -d '[:space:]')
  if [ "$cur" = "blue" ]; then
    echo "green"
  else
    echo "blue"
  fi
}

slot_ports() {
  case "$1" in
    blue)  BE_PORT=8101; FE_PORT=8201;;
    green) BE_PORT=8102; FE_PORT=8202;;
    *) return 1;;
  esac
}

get_slot_port() {
  local slot
  slot=$(echo "$1" | tr -d '[:space:]')
  if [ "$slot" = "blue" ]; then
    echo "8101"
  else
    echo "8102"
  fi
}

acquire_lock() {
  exec 9>"$STATE/deploy.lock"
  if ! flock -n 9; then
    printf '%s another deploy/rollback holds %s - exiting %d\n' "$(date -u +%FT%TZ)" "$STATE/deploy.lock" "$EX_BUSY" >&2
    exit "$EX_BUSY"
  fi
}

# Robust read: strips all \r, spaces, and newlines
read_active_slot() {
  local s=""
  if [ -f "$STATE/active_slot" ]; then
    s=$(tr -d '[:space:]' < "$STATE/active_slot" 2>/dev/null || echo "")
  fi
  if [ "$s" = "blue" ]; then
    echo "blue"
  elif [ "$s" = "green" ]; then
    echo "green"
  else
    echo "green"
  fi
}

write_active_slot() {
  local slot
  slot=$(echo "$1" | tr -d '[:space:]')
  mkdir -p "$STATE"
  local tmp
  tmp=$(mktemp "$STATE/active_slot.XXXXXX")
  printf '%s' "$slot" > "$tmp"
  mv -f "$tmp" "$STATE/active_slot"
  chmod 644 "$STATE/active_slot"
}

compose_slot() {
  local slot=$1; shift
  docker compose -p "gym-$slot" -f "$COMPOSE_DIR/compose.slot.yml" "$@"
}
