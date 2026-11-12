#!/usr/bin/env bash
# =============================================================================
# Project 03 · Automated DB Backup & Cloud Sync — retention rotation
# =============================================================================
# Two rules, both must allow deletion:
#   1. the archive is older than BACKUP_RETENTION_DAYS
#   2. at least BACKUP_KEEP_MINIMUM newer archives exist
# Rule 2 protects against a long outage where every archive is "too old"
# but also the only copies that exist.

set -Eeuo pipefail

log() { printf '%s [rotate] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

: "${BACKUP_ARCHIVE_DIR:=/backups}"
: "${BACKUP_RETENTION_DAYS:=7}"
: "${BACKUP_KEEP_MINIMUM:=3}"

shopt -s nullglob
archives=("${BACKUP_ARCHIVE_DIR}"/*.tar.gz)
count=${#archives[@]}

if [ "$count" -eq 0 ]; then
  log "no archives present, nothing to rotate"
  exit 0
fi

cutoff=$(( $(date -u +%s) - BACKUP_RETENTION_DAYS * 86400 ))
removed=0
index=0

# Oldest first, ordered by modification time rather than by filename. Archive
# names happen to sort chronologically, but a renamed or restored copy would not,
# and "how many are newer than this one" has to mean real age or the keep-minimum
# rule protects the wrong files.
while IFS= read -r archive; do
  [ -n "$archive" ] || continue
  index=$((index + 1))
  newer=$((count - index))
  modified=$(date -u -r "$archive" +%s)

  if [ "$modified" -lt "$cutoff" ] && [ "$newer" -ge "$BACKUP_KEEP_MINIMUM" ]; then
    log "removing $(basename "$archive") (age exceeds ${BACKUP_RETENTION_DAYS}d, ${newer} newer kept)"
    rm -f "$archive" "${archive}.sha256"
    removed=$((removed + 1))
  fi
done < <(ls -1tr -- "${archives[@]}")

log "rotation complete: ${removed} removed, $((count - removed)) retained (policy ${BACKUP_RETENTION_DAYS}d / keep>=${BACKUP_KEEP_MINIMUM})"
