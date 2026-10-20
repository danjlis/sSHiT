# notify.sh -- chat notification hook (Mattermost and Slack incoming webhooks share the {"text":...} format)

json_escape() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | awk 'NR>1{printf "\\n"}{printf "%s",$0}'; }

# notify <check> <status> <summary> <report-link>
notify() {
  local check=$1 status=$2 summary=$3 link=$4
  if [ -n "$SHIRT_NO_NOTIFY" ] || [ -z "$SHIRT_WEBHOOK_URL" ]; then
    log "notify skipped ($check: $status)"
    return 0
  fi
  if [ "$(status_rank "$status")" -lt "$(status_rank "${SHIRT_NOTIFY_ON:-WARN}")" ]; then
    log "notify skipped: $status below threshold ${SHIRT_NOTIFY_ON:-WARN}"
    return 0
  fi
  local icon
  case "$status" in OK) icon=":white_check_mark:" ;; INFO) icon=":information_source:" ;;
                    WARN) icon=":warning:" ;; *) icon=":x:" ;; esac
  local text
  text=$(printf '%s **shirt / %s: %s**\n%s\n%s' "$icon" "$check" "$status" "$summary" "$link" | json_escape)
  local body
  body=$(printf '{"text":"%s","username":"%s"}' "$text" "${SHIRT_NOTIFY_USERNAME:-shirt}")
  if curl -sS -m 20 -X POST -H 'Content-Type: application/json' -d "$body" "$SHIRT_WEBHOOK_URL" >/dev/null; then
    log "notification sent ($check: $status)"
  else
    log "WARNING: notification failed ($check)"
  fi
}
