#!/usr/bin/env bash
# =============================================================================
# Project 03 · Automated DB Backup & Cloud Sync — one backup run
# =============================================================================
# Produces, in the archive directory:
#   <db>_<UTC timestamp>.tar.gz          pg_dump custom-format dump + manifest
#   <db>_<UTC timestamp>.tar.gz.sha256   integrity checksum for transfer
#
# The manifest records what was dumped, when, how big and with which client
# version — enough to audit a restore without opening the archive.
# No credential value is ever written into the archive or the manifest.

set -Eeuo pipefail

log() { printf '%s [backup] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

: "${PGHOST:=postgres}"
: "${PGPORT:=5432}"
: "${PGDATABASE:=appdb}"
: "${PGUSER:=appuser}"
: "${BACKUP_ARCHIVE_DIR:=/backups}"

mkdir -p "$BACKUP_ARCHIVE_DIR"

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
stem="${PGDATABASE}_${timestamp}"
archive="${BACKUP_ARCHIVE_DIR}/${stem}.tar.gz"
workdir=$(mktemp -d)
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

log "dumping ${PGDATABASE} from ${PGHOST}:${PGPORT} as ${PGUSER}"
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
  "encryption": "reserved for Stage 3 (age/gpg hook)"
}
JSON

tar -czf "$archive" -C "$workdir" "${stem}.dump" manifest.json
( cd "$BACKUP_ARCHIVE_DIR" && sha256sum "${stem}.tar.gz" > "${stem}.tar.gz.sha256" )

archive_bytes=$(wc -c < "$archive" | tr -d ' ')
log "archive written: ${stem}.tar.gz (${archive_bytes} bytes, dump ${dump_bytes} bytes)"

/usr/local/bin/rotate.sh
/usr/local/bin/sync.sh
