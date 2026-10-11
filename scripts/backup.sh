#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [ -f /etc/gym/backup.env ]; then
  source /etc/gym/backup.env
fi

BACKUP_DIR=${BACKUP_DIR:-/var/backups/gym}
PASSPHRASE_FILE=${PASSPHRASE_FILE:-/etc/gym/backup/passphrase}
GNUPGHOME=${GNUPGHOME:-/var/lib/gym-backup/gnupg}
ADMIN_USER=${ADMIN_USER:-student}
PG_CONTAINER=${PG_CONTAINER:-gym-postgres}
PG_USER=${PG_USER:-gym_user}
PG_DB=${PG_DB:-gym_db}
UPLOADS_DIR=${UPLOADS_DIR:-/srv/gym/uploads}
RETENTION_DAYS=${RETENTION_DAYS:-14}
KEEP_MIN=${KEEP_MIN:-7}
METRIC=/var/lib/node_exporter/textfile/gym_backup.prom
export GNUPGHOME

TS=$(date -u +%Y%m%dT%H%M%SZ)
DB_OUT="$BACKUP_DIR/db/gym_$TS.dump.gpg"
UP_OUT="$BACKUP_DIR/uploads/uploads_$TS.tar.gz.gpg"

GPG=(gpg --batch --yes --quiet --no-tty --pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE")
ENCRYPT=("${GPG[@]}" --symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 --compress-algo none)

log() { printf '%s backup: %s\n' "$(date -u +%FT%TZ)" "$*"; }

write_metric() {
  local ok=$1 now last tmp
  now=$(date +%s)
  last=$(awk '/^gym_backup_last_success_timestamp_seconds /{print $2}' "$METRIC" 2>/dev/null || true)
  if [ "$ok" = 1 ]; then last=$now; fi
  tmp=$(mktemp "$METRIC.XXXXXX")
  {
    echo "# HELP gym_backup_last_run_success 1 if the most recent backup run succeeded."
    echo "# TYPE gym_backup_last_run_success gauge"
    echo "gym_backup_last_run_success $ok"
    echo "gym_backup_last_run_timestamp_seconds $now"
    if [ -n "$last" ]; then echo "gym_backup_last_success_timestamp_seconds $last"; fi
    if [ "$ok" = 1 ]; then
      echo "gym_backup_last_size_bytes{kind=\"db\"} $(stat -c %s "$DB_OUT")"
      echo "gym_backup_last_size_bytes{kind=\"uploads\"} $(stat -c %s "$UP_OUT")"
    fi
  } > "$tmp"
  chmod 0644 "$tmp" && mv -f "$tmp" "$METRIC"
}

cleanup() { rm -f -- "$DB_OUT.partial" "$UP_OUT.partial"; }
fail() { [ "$BASHPID" = "$$" ] || exit 1; trap - ERR TERM INT; log "FAILED: $*"; cleanup; write_metric 0; exit 1; }
trap 'fail "command failed at line $LINENO"' ERR
trap 'fail "terminated by signal"' TERM INT
trap cleanup EXIT

mkdir -p /run/lock
exec 8>/run/lock/gym-backup.lock
flock -n 8 || { log "another backup run is in progress — nothing to do"; exit 0; }

[ -s "$PASSPHRASE_FILE" ] || fail "passphrase file $PASSPHRASE_FILE is missing"
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$BACKUP_DIR" "$BACKUP_DIR/db" "$BACKUP_DIR/uploads"

if [ -f /etc/gym/secrets/postgres_password ]; then
  export PGPASSWORD="$(cat /etc/gym/secrets/postgres_password)"
fi

docker exec ${PGPASSWORD:+-e PGPASSWORD="$PGPASSWORD"} "$PG_CONTAINER" pg_isready -q -U "$PG_USER" -d "$PG_DB" || fail "database is not ready"

log "1/4 database → $(basename "$DB_OUT")"
docker exec ${PGPASSWORD:+-e PGPASSWORD="$PGPASSWORD"} "$PG_CONTAINER" pg_dump -U "$PG_USER" -d "$PG_DB" --format=custom --compress=6 \
  | "${ENCRYPT[@]}" --output "$DB_OUT.partial"

log "2/4 uploads → $(basename "$UP_OUT")"
mkdir -p "$UPLOADS_DIR"
touch "$UPLOADS_DIR/.keep"
{ tar --warning=no-file-changed -C "$(dirname "$UPLOADS_DIR")" -czf - "$(basename "$UPLOADS_DIR")" 2>/dev/null || [ $? -le 1 ]; } \
  | "${ENCRYPT[@]}" --output "$UP_OUT.partial"

log "3/4 verify: both archives decrypt"
"${GPG[@]}" --decrypt "$DB_OUT.partial" | docker exec -i ${PGPASSWORD:+-e PGPASSWORD="$PGPASSWORD"} "$PG_CONTAINER" pg_restore --list >/dev/null \
  || fail "database archive invalid"
"${GPG[@]}" --decrypt "$UP_OUT.partial" | tar -tzf - >/dev/null || fail "uploads archive invalid"

mv -f "$DB_OUT.partial" "$DB_OUT"
mv -f "$UP_OUT.partial" "$UP_OUT"
chown "$ADMIN_USER:" "$DB_OUT" "$UP_OUT"
chmod 0600 "$DB_OUT" "$UP_OUT"

log "4/4 retention prune"
find "$BACKUP_DIR/db" -maxdepth 1 -type f -name '*.gpg' -printf '%T@ %p\n' | sort -rn | tail -n +8 | cut -d' ' -f2- | while IFS= read -r f; do
  if [ -n "$(find "$f" -mtime +14 2>/dev/null)" ]; then rm -f -- "$f"; fi
done
find "$BACKUP_DIR/uploads" -maxdepth 1 -type f -name '*.gpg' -printf '%T@ %p\n' | sort -rn | tail -n +8 | cut -d' ' -f2- | while IFS= read -r f; do
  if [ -n "$(find "$f" -mtime +14 2>/dev/null)" ]; then rm -f -- "$f"; fi
done

write_metric 1
log "done: $(basename "$DB_OUT") $(stat -c %s "$DB_OUT") B · $(basename "$UP_OUT") $(stat -c %s "$UP_OUT") B"
