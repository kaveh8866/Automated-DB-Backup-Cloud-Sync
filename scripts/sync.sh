#!/usr/bin/env bash
# =============================================================================
# Automated DB Backup & Cloud Sync — cloud sync
# =============================================================================
# BACKUP_SYNC_MODE
#   local  -> copy archives into the archive volume (offline/mock cloud target)
#   rclone -> push to an S3-compatible bucket (OCI Object Storage) and verify
#   off    -> archive only
#
# Sync is provider-blind: it moves whatever archive.sh produced, whether that is
# a plaintext .tar.gz or an encrypted .tar.gz.enc, plus its .sha256 sidecar.
#
# rclone is used instead of the AWS CLI because the same binary speaks OCI's
# S3-compatible endpoint, S3, GCS and R2 — no extra SDK in the image.

set -Eeuo pipefail

# shellcheck source=/dev/null
. /usr/local/bin/alert.sh

log() { printf '%s [sync] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

: "${BACKUP_ARCHIVE_DIR:=/backups}"
: "${BACKUP_SYNC_MODE:=local}"
: "${BACKUP_LOCAL_SYNC_DIR:=${BACKUP_ARCHIVE_DIR}/mock-cloud-sync}"
: "${RCLONE_REMOTE:=}"
: "${RCLONE_DEST_PATH:=}"
: "${RCLONE_CONFIG:=/etc/rclone/rclone.conf}"

# When backup.sh drives this script it sets ALERT_SUPPRESS=1 and reports the
# failure itself; run standalone, the stage alerts on its own.
if [ "${ALERT_SUPPRESS:-0}" != "1" ]; then
  trap 'rc=$?; alert critical sync "sync aborted with exit ${rc}"' ERR
fi

case "$BACKUP_SYNC_MODE" in
  local)
    mkdir -p "$BACKUP_LOCAL_SYNC_DIR"
    copied=0
    shopt -s nullglob
    # Matches .tar.gz, .tar.gz.enc and both .sha256 sidecars.
    for file in "${BACKUP_ARCHIVE_DIR}"/*.tar.gz*; do
      target="${BACKUP_LOCAL_SYNC_DIR}/$(basename "$file")"
      if [ ! -f "$target" ] || ! cmp -s "$file" "$target"; then
        cp -p "$file" "$target"
        copied=$((copied + 1))
      fi
    done
    log "local sync complete: ${copied} file(s) copied to ${BACKUP_LOCAL_SYNC_DIR}"
    ;;
  rclone)
    if [ -z "$RCLONE_REMOTE" ]; then
      log "BACKUP_SYNC_MODE=rclone requires RCLONE_REMOTE (for example: oci-backups)"
      alert critical sync "rclone mode configured without RCLONE_REMOTE"
      exit 1
    fi
    if [ ! -r "$RCLONE_CONFIG" ]; then
      log "missing rclone config at ${RCLONE_CONFIG} (copy the template and mount the real file outside Git)"
      alert critical sync "rclone config missing at ${RCLONE_CONFIG}"
      exit 1
    fi
    destination="${RCLONE_REMOTE}:${RCLONE_DEST_PATH}"
    log "uploading archives to ${destination}"
    rclone copy "$BACKUP_ARCHIVE_DIR" "$destination" \
      --config "$RCLONE_CONFIG" \
      --include "*.tar.gz" \
      --include "*.tar.gz.enc" \
      --include "*.sha256" \
      --checksum \
      --stats-one-line
    rclone check "$BACKUP_ARCHIVE_DIR" "$destination" \
      --config "$RCLONE_CONFIG" \
      --include "*.tar.gz" \
      --include "*.tar.gz.enc" \
      --include "*.sha256" \
      --one-way \
      --size-only
    log "rclone sync verified against ${destination}"
    ;;
  off)
    log "sync disabled (BACKUP_SYNC_MODE=off)"
    ;;
  *)
    log "unknown BACKUP_SYNC_MODE=${BACKUP_SYNC_MODE} (expected local|rclone|off)"
    alert critical sync "unknown BACKUP_SYNC_MODE=${BACKUP_SYNC_MODE}"
    exit 1
    ;;
esac
