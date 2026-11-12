#!/usr/bin/env bash
# =============================================================================
# Project 03 · Automated DB Backup & Cloud Sync — scheduler
# =============================================================================
# Waits for the database, then runs one backup cycle per interval:
#   backup.sh  (dump -> tar.gz + manifest + checksum)
#   rotate.sh  (retention pruning, called by backup.sh)
#   sync.sh    (cloud sync, called by backup.sh)
#
# Defaults come from /etc/backup/backup.conf; environment variables win because
# the config only fills unset values (`: "${VAR:=default}"`).

set -Eeuo pipefail

log() { printf '%s [entrypoint] %s\n' "$(date -u +%FT%TZ)" "$*"; }

: "${BACKUP_CONF:=/etc/backup/backup.conf}"
if [ -r "$BACKUP_CONF" ]; then
  # shellcheck disable=SC1090
  . "$BACKUP_CONF"
  log "loaded defaults from $BACKUP_CONF"
fi

: "${PGHOST:=postgres}"
: "${PGPORT:=5432}"
: "${PGUSER:=appuser}"
: "${BACKUP_INTERVAL_SECONDS:=3600}"
: "${BACKUP_RETENTION_DAYS:=7}"
: "${BACKUP_KEEP_MINIMUM:=3}"
: "${BACKUP_SYNC_MODE:=local}"

shutdown() {
  log "shutdown signal received, exiting cleanly"
  exit 0
}
trap shutdown TERM INT

log "runner starting: interval=${BACKUP_INTERVAL_SECONDS}s retention=${BACKUP_RETENTION_DAYS}d keep>=${BACKUP_KEEP_MINIMUM} sync=${BACKUP_SYNC_MODE}"

# Wait for the database to accept connections before the first dump.
reachable=0
for attempt in $(seq 1 30); do
  if pg_isready -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" >/dev/null 2>&1; then
    log "database ${PGHOST}:${PGPORT} reachable after ${attempt} attempt(s)"
    reachable=1
    break
  fi
  log "waiting for database ${PGHOST}:${PGPORT} (attempt ${attempt}/30)"
  sleep 2
done
if [ "$reachable" -ne 1 ]; then
  log "database never became reachable; the cycle loop will keep retrying"
fi

while :; do
  started_at=$(date -u +%s)
  if /usr/local/bin/backup.sh; then
    log "backup cycle completed"
  else
    log "backup cycle failed (exit $?); will retry next interval"
  fi

  elapsed=$(( $(date -u +%s) - started_at ))
  sleep_for=$(( BACKUP_INTERVAL_SECONDS - elapsed ))
  if [ "$sleep_for" -lt 5 ]; then
    sleep_for=5
  fi
  log "next cycle in ${sleep_for}s"
  # Background sleep + wait so the TERM trap fires immediately.
  sleep "$sleep_for" &
  wait $!
done
