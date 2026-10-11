#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [ -f /etc/gym/backup.env ]; then
  source /etc/gym/backup.env
fi

BACKUP_DIR=${BACKUP_DIR:-/var/backups/gym}
PASSPHRASE_FILE=${PASSPHRASE_FILE:-/etc/gym/backup/passphrase}
GNUPGHOME=${GNUPGHOME:-/var/lib/gym-backup/gnupg}
PG_CONTAINER=${PG_CONTAINER:-gym-postgres}
PG_USER=${PG_USER:-gym_user}
PG_DB=${PG_DB:-gym_db}
PG_IMAGE=${PG_IMAGE:-postgres:16-alpine}
UPLOADS_DIR=${UPLOADS_DIR:-/srv/gym/uploads}
METRIC=/var/lib/node_exporter/textfile/gym_restore_test.prom
REPORT_DIR=/var/log/gym/restore-tests
export GNUPGHOME

C="gym-restore-test-$$"
START=$(date +%s); TS=$(date -u +%Y%m%dT%H%M%SZ)
REPORT="$REPORT_DIR/restore-test-$TS.md"
DECRYPT=(gpg --batch --quiet --no-tty --pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE" --decrypt)

log()    { printf '%s restore-test: %s\n' "$(date -u +%FT%TZ)" "$*"; }
report() { printf '%s\n' "$@" >> "$REPORT"; }

write_metric() {
  local ok=$1 now last tmp; now=$(date +%s)
  last=$(awk '/^gym_restore_test_last_success_timestamp_seconds /{print $2}' "$METRIC" 2>/dev/null || true)
  if [ "$ok" = 1 ]; then last=$now; fi
  tmp=$(mktemp "$METRIC.XXXXXX")
  {
    echo "# HELP gym_restore_test_last_run_success 1 if the most recent restore test passed."
    echo "# TYPE gym_restore_test_last_run_success gauge"
    echo "gym_restore_test_last_run_success $ok"
    if [ -n "$last" ]; then echo "gym_restore_test_last_success_timestamp_seconds $last"; fi
    if [ -n "${2:-}" ]; then echo "gym_restore_test_duration_seconds $2"; fi
  } > "$tmp"
  chmod 0644 "$tmp" && mv -f "$tmp" "$METRIC"
}

cleanup() { docker rm -fv "$C" >/dev/null 2>&1 || true; }
fail() { [ "$BASHPID" = "$$" ] || exit 1; trap - ERR TERM INT; log "FAILED: $*"; report "" "**RESULT: FAILED** — $*"; write_metric 0; exit 1; }
trap 'fail "command failed at line $LINENO"' ERR
trap 'fail "terminated by signal"' TERM INT
trap cleanup EXIT

install -d -m 0750 "$REPORT_DIR"
newest() { find "$1" -maxdepth 1 -type f -name '*.gpg' -printf '%T@ %p\n' | sort -rn | sed -n '1s/^[^ ]* //p'; }
DB_FILE=$(newest "$BACKUP_DIR/db")
UP_FILE=$(newest "$BACKUP_DIR/uploads")

{
  echo "# Restore Test Report — $TS"; echo
  echo "| Check | Result |"; echo "|-------|--------|"
} > "$REPORT"

[ -n "$DB_FILE" ] || fail "no database backup in $BACKUP_DIR/db"
[ -n "$UP_FILE" ] || fail "no uploads backup in $BACKUP_DIR/uploads"

AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$DB_FILE") ) / 3600 ))
report "| Database backup | \`$(basename "$DB_FILE")\` ($AGE_H h old) |" \
       "| Uploads backup | \`$(basename "$UP_FILE")\` |" "| Postgres image | \`$PG_IMAGE\` |"

log "starting throwaway $PG_IMAGE (no network)"
docker run -d --name "$C" --network none \
  -e POSTGRES_USER="$PG_USER" -e POSTGRES_DB=restore_test -e POSTGRES_PASSWORD="$(openssl rand -hex 16)" \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  "$PG_IMAGE" >/dev/null

for _ in $(seq 1 60); do
  docker exec "$C" pg_isready -q -h 127.0.0.1 -U "$PG_USER" -d restore_test && break
  sleep 2
done
docker exec "$C" pg_isready -q -h 127.0.0.1 -U "$PG_USER" -d restore_test || fail "throwaway DB not ready"

log "restoring $(basename "$DB_FILE")"
T0=$(date +%s)
"${DECRYPT[@]}" "$DB_FILE" \
  | docker exec -i "$C" pg_restore -U "$PG_USER" -d restore_test --no-owner --exit-on-error \
  || fail "pg_restore failed"
report "| Database restore time | $(( $(date +%s) - T0 )) s |"

q() { docker exec "$C" psql -U "$PG_USER" -d restore_test -Atqc "$1"; }
TABLES=$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
report "| Tables restored | $TABLES |"

log "checking $(basename "$UP_FILE")"
FILES=$("${DECRYPT[@]}" "$UP_FILE" | tar -tzf - | wc -l) || fail "uploads archive invalid"
LIVE_FILES=$(find "$UPLOADS_DIR" -type f 2>/dev/null | wc -l || echo 0)
report "| Files in uploads archive / live now | $FILES / $LIVE_FILES |"

DURATION=$(( $(date +%s) - START ))
report "| Total duration (≈ RTO) | $DURATION s |" "" "**RESULT: PASSED**"
write_metric 1 "$DURATION"
log "passed in $DURATION s — report: $REPORT"
