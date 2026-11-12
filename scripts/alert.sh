#!/usr/bin/env bash
# =============================================================================
# Project 03 · Automated DB Backup & Cloud Sync — failure notification hook
# =============================================================================
# Sourced by backup.sh and sync.sh. Emits one structured line on stderr and, when
# ALERT_WEBHOOK_URL is set, POSTs the same event as JSON.
#
# Deliberately best-effort: a webhook that is slow, broken or missing must never
# change the outcome of a backup cycle. Delivery failures are logged and ignored.
#
#   ALERT_WEBHOOK_URL        JSON endpoint (Slack, Discord, Teams, ntfy, n8n,
#                            Grafana alerting, a CloudGuard endpoint placeholder)
#   ALERT_TIMEOUT_SECONDS    curl timeout, default 10
#   ALERT_SUPPRESS=1         child processes skip their own trap so the
#                            orchestrator (backup.sh) does not double-alert
#
# Payload shape (Slack-compatible superset):
#   {"text": "[CloudGuard] <level>/<stage>: <message>",
#    "level": "...", "stage": "...", "project": "...", "host": "..."}

alert() {
  _level="${1:-critical}"
  _stage="${2:-backup}"
  shift 2 2>/dev/null || true
  _message="$*"

  printf '%s [alert] level=%s stage=%s %s\n' \
    "$(date -u +%FT%TZ)" "$_level" "$_stage" "$_message" >&2

  if [ -z "${ALERT_WEBHOOK_URL:-}" ]; then
    printf '%s [alert] ALERT_WEBHOOK_URL unset — notification is log-only\n' \
      "$(date -u +%FT%TZ)" >&2
    return 0
  fi

  _escaped=$(printf '%s' "$_message" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n')
  _payload=$(printf '{"text":"[CloudGuard] %s/%s: %s","level":"%s","stage":"%s","project":"03-automated-db-backup-cloud-sync","host":"%s"}' \
    "$_level" "$_stage" "$_escaped" "$_level" "$_stage" "$(hostname 2>/dev/null || echo unknown)")

  if curl -fsS --max-time "${ALERT_TIMEOUT_SECONDS:-10}" \
       -H 'Content-Type: application/json' \
       --data "$_payload" \
       "$ALERT_WEBHOOK_URL" >/dev/null 2>&1; then
    printf '%s [alert] webhook delivered to %s\n' "$(date -u +%FT%TZ)" "$ALERT_WEBHOOK_URL" >&2
  else
    printf '%s [alert] webhook delivery failed (%s) — log-only\n' \
      "$(date -u +%FT%TZ)" "$ALERT_WEBHOOK_URL" >&2
  fi
  return 0
}
