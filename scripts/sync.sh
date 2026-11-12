#!/usr/bin/env bash
# =============================================================================
# Project 03 · Automated DB Backup & Cloud Sync — cloud sync
# =============================================================================
# BACKUP_SYNC_MODE
#   local  -> copy archives into the archive volume (offline/mock cloud target)
#   rclone -> push to an S3-compatible bucket (OCI Object Storage) and verify
#   off    -> archive only
#
# rclone is used instead of the AWS CLI because the same binary speaks OCI's
# S3-compatible endpoint, S3, GCS and R2 — no extra SDK in the image.

set -Eeuo pipefail

log() { printf '%s [sync] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

: "${BACKUP_ARCHIVE_DIR:=/backups}"
: "${BACKUP_SYNC_MODE:=local}"
: "${BACKUP_LOCAL_SYNC_DIR:=${BACKUP_ARCHIVE_DIR}/mock-cloud-sync}"
: "${RCLONE_REMOTE:=}"
: "${RCLONE_DEST_PATH:=}"
: "${RCLONE_CONFIG:=/etc/rclone/rclone.conf}"

case "$BACKUP_SYNC_MODE" in
  local)
    mkdir -p "$BACKUP_LOCAL_SYNC_DIR"
    copied=0
    shopt -s nullglob
    for file in "${BACKUP_ARCHIVE_DIR}"/*.tar.gz "${BACKUP_ARCHIVE_DIR}"/*.sha256; do
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
      exit 1
    fi
    if [ ! -r "$RCLONE_CONFIG" ]; then
      log "missing rclone config at ${RCLONE_CONFIG} (copy the template and mount the real file outside Git)"
      exit 1
    fi
    destination="${RCLONE_REMOTE}:${RCLONE_DEST_PATH}"
    log "uploading archives to ${destination}"
    rclone copy "$BACKUP_ARCHIVE_DIR" "$destination" \
      --config "$RCLONE_CONFIG" \
      --include "*.tar.gz" \
      --include "*.sha256" \
      --checksum \
      --stats-one-line
    rclone check "$BACKUP_ARCHIVE_DIR" "$destination" \
      --config "$RCLONE_CONFIG" \
      --include "*.tar.gz" \
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
    exit 1
    ;;
esac
