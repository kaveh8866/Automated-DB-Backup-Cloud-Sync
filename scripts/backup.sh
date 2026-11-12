#!/usr/bin/env bash
# =============================================================================
# Automated DB Backup & Cloud Sync — one backup run
# =============================================================================
# Produces, in the archive directory:
#   <db>_<UTC timestamp>.tar.gz          pg_dump custom dump + manifest
#   <db>_<UTC timestamp>.tar.gz.sha256   integrity checksum for transfer
#   <db>_<UTC timestamp>.tar.gz.enc      when BACKUP_ENCRYPTION=openssl: the
#                                        plaintext archive is removed and the
#                                        sidecar covers the .enc file instead
#
# The manifest records what was dumped, when, how big, with which client version
# and how it was encrypted — enough to audit a restore without opening the
# archive. No credential value is ever written into the archive or the manifest.
#
# Failure path: every abort runs the ERR trap, which emits exactly one alert
# (stderr line plus optional webhook, see alert.sh) tagged with the stage that
# failed: backup, rotate or sync.

set -Eeuo pipefail

# shellcheck source=/dev/null
. /usr/local/bin/alert.sh

log() { printf '%s [backup] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

: "${PGHOST:=postgres}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=appdb}"
: "${PGUSER:=appuser}"
: "${BACKUP_ARCHIVE_DIR:=/backups}"
: "${BACKUP_ENCRYPTION:=off}"
: "${BACKUP_ENCRYPTION_PASSPHRASE:=}"
: "${BACKUP_ENCRYPTION_PASSPHRASE_FILE:=}"

CURRENT_STAGE=backup
trap 'rc=$?; alert critical "${CURRENT_STAGE}" "backup cycle aborted with exit ${rc}"' ERR

mkdir -p "$BACKUP_ARCHIVE_DIR"

case "$BACKUP_ENCRYPTION" in
  off|none|"") encryption_label="none" ;;
  openssl)     encryption_label="openssl aes-256-cbc/pbkdf2 (200k iterations)" ;;
  *)
    alert critical backup "unknown BACKUP_ENCRYPTION=${BACKUP_ENCRYPTION} (expected off|openssl)"
    exit 1
    ;;
esac

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
stem="${PGDATABASE}_${timestamp}"
plain="${BACKUP_ARCHIVE_DIR}/${stem}.tar.gz"
workdir=$(mktemp -d)
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

log "dumping ${PGDATABASE} from ${PGHOST}:${PGPORT} as ${PGUSER} (encryption=${BACKUP_ENCRYPTION})"
pg_dump \
  --format=custom \
  --compress=6 \
  --no-owner \
  --no-privileges \
  --file "${workdir}/${stem}.dump" \
  "$PGDATABASE"

dump_bytes=$(wc -c < "${workdir}/${stem}.dump" | tr -d ' ')
dump_sha=$(sha256sum "${workdir}/${stem}.dump" | awk '{print $1}')
client_version=$(pg_dump --version | awk '{print $NF}')

cat > "${workdir}/manifest.json" <<JSON
{
  "database": "${PGDATABASE}",
  "host": "${PGHOST}",
  "created_at": "${timestamp}",
  "dump_format": "pg_dump custom (zlib)",
  "dump_bytes": ${dump_bytes},
  "dump_sha256": "${dump_sha}",
  "pg_client_version": "${client_version}",
  "encryption": "${encryption_label}"
}
JSON

tar -czf "$plain" -C "$workdir" "${stem}.dump" manifest.json

archive="$plain"
if [ "$BACKUP_ENCRYPTION" = "openssl" ]; then
  if [ -n "$BACKUP_ENCRYPTION_PASSPHRASE" ]; then
    export BACKUP_ENCRYPTION_PASSPHRASE
    pass_args=(-pass env:BACKUP_ENCRYPTION_PASSPHRASE)
  elif [ -n "$BACKUP_ENCRYPTION_PASSPHRASE_FILE" ]; then
    if [ ! -r "$BACKUP_ENCRYPTION_PASSPHRASE_FILE" ]; then
      alert critical backup "passphrase file not readable: ${BACKUP_ENCRYPTION_PASSPHRASE_FILE}"
      exit 1
    fi
    pass_args=(-pass "file:${BACKUP_ENCRYPTION_PASSPHRASE_FILE}")
  else
    alert critical backup "BACKUP_ENCRYPTION=openssl requires BACKUP_ENCRYPTION_PASSPHRASE or BACKUP_ENCRYPTION_PASSPHRASE_FILE"
    exit 1
  fi

  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
    -in "$plain" -out "${plain}.enc" "${pass_args[@]}"
  # At-rest encryption is only meaningful if the plaintext stops existing.
  rm -f "$plain"
  archive="${plain}.enc"
  log "encrypted with AES-256 (pbkdf2), plaintext archive removed"
fi

archive_name=$(basename "$archive")
archive_bytes=$(wc -c < "$archive" | tr -d ' ')
( cd "$BACKUP_ARCHIVE_DIR" && sha256sum "$archive_name" > "${archive_name}.sha256" )

log "archive written: ${archive_name} (${archive_bytes} bytes, dump ${dump_bytes} bytes, encryption=${BACKUP_ENCRYPTION})"

# Children inherit ALERT_SUPPRESS so a failure here is reported once, by the
# orchestrator, with the stage that actually broke.
CURRENT_STAGE=rotate
ALERT_SUPPRESS=1 /usr/local/bin/rotate.sh

CURRENT_STAGE=sync
ALERT_SUPPRESS=1 /usr/local/bin/sync.sh
