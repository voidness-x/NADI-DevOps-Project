#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BASE=/opt/gym; STATE=$BASE/state; DEVOPS=$BASE/devops; COMPOSE_DIR=$DEVOPS/compose; LOG_DIR=/var/log/gym
TEXTFILE_DIR=/var/lib/node_exporter/textfile
EX_BUSY=75
TAG_RE='^[0-9a-f]{12}$'

log()    { printf '%s [%s] %s
' "$(date -u +%FT%TZ)" "${DEPLOY_ID:-n/a}" "$*"; }
other_slot() { if [ "$1" = blue ]; then echo green; else echo blue; fi; }

# CRITICAL FIX: Explicit slot ports (Blue=8101/8201, Green=8102/8202)
slot_ports() {
  case "$1" in
    blue)  BE_PORT=8101; FE_PORT=8201;;
    green) BE_PORT=8102; FE_PORT=8202;;
    *) return 1;;
  esac
}

get_slot_port() {
  local slot="$1"
  if [[ "${slot}" == "blue" ]]; then
    echo "8101"
  else
    echo "8102"
  fi
}

acquire_lock() {
  exec 9>"$STATE/deploy.lock"
  if ! flock -n 9; then
    printf '%s another deploy/rollback holds %s - exiting %d
' "$(date -u +%FT%TZ)" "$STATE/deploy.lock" "$EX_BUSY" >&2
    exit "$EX_BUSY"
  fi
}

read_active_slot() {
  local s; s=$(<"$STATE/active_slot" 2>/dev/null || echo "green")
  [[ $s =~ ^(blue|green)$ ]] || s="green"
  echo "$s"
}

write_active_slot() {
  local tmp; tmp=$(mktemp "$STATE/active_slot.XXXXXX")
  echo "$1" > "$tmp"; mv -f "$tmp" "$STATE/active_slot"
}

compose_slot() {
  local slot=$1; shift
  docker compose -p "gym-$slot" -f "$COMPOSE_DIR/compose.slot.yml" "$@"
}

wait_http() {
  local url=$1 tries=${2:-40} i
  for ((i=1; i<=tries; i++)); do
    curl -fsS -m 3 "$url" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
