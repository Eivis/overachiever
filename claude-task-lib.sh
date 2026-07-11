#!/usr/bin/env bash
# claude-task-lib.sh - shared helpers for run-tasks.sh and resume-session.sh
set -euo pipefail

RESUME_GRACE_SECONDS="${RESUME_GRACE_SECONDS:-60}"
USAGE_LIMIT_FALLBACK_WAIT="${USAGE_LIMIT_FALLBACK_WAIT:-18000}"
IDLE_HEARTBEAT_SECONDS="${IDLE_HEARTBEAT_SECONDS:-300}"
SESSION_ID_FILE="${SESSION_ID_FILE:-.claude-session-id}"

JQ_STREAM_FILTER='
  if .type == "stream_event"
     and .event.type == "content_block_delta"
     and .event.delta.type == "text_delta" then
    .event.delta.text
  elif .type == "result" and (.result != null) then
    ("\n" + .result + "\n")
  else
    empty
  end
'

save_session_id() {
  local sid="$1"
  if [[ -n "$sid" ]]; then
    printf '%s\n' "$sid" > "$SESSION_ID_FILE"
  fi
}

print_resume_help() {
  local sid=""
  if [[ -f "$SESSION_ID_FILE" ]]; then
    sid="$(cat "$SESSION_ID_FILE")"
  fi
  echo
  echo "Resume later with one of these:"
  if [[ -n "$sid" ]]; then
    echo "  claude -r \"$sid\""
    echo "  claude --resume \"$sid\""
    echo "  claude -c"
  else
    echo "  claude -c"
    echo "  claude --resume <session-id>"
  fi
  echo
}

is_usage_limit_error() {
  local text="$1"
  if printf '%s' "$text" | grep -qiE 'not your usage limit'; then
    return 1
  fi
  printf '%s' "$text" | grep -qiE \
    '(usage|session|weekly|opus)[[:space:]]+limit[[:space:]]+(reached|exceeded)|hit[[:space:]]+(your|the)[[:space:]]+(session|weekly|usage)[[:space:]]+limit|usage[[:space:]]+limit[[:space:]]+reached\|[0-9]+'
}

_spec_to_epoch() {
  local spec="$1"
  local epoch=""
  if epoch="$(date -d "$spec" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"; return 0
  fi
  if command -v gdate >/dev/null 2>&1 && epoch="$(gdate -d "$spec" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"; return 0
  fi
  local compact
  compact="$(printf '%s' "$spec" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  if epoch="$(date -j -f "%I:%M%p" "$compact" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"; return 0
  fi
  if epoch="$(date -j -f "%I%p" "$compact" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"; return 0
  fi
  return 1
}

parse_reset_epoch() {
  local text="$1"
  local now_epoch
  now_epoch="$(date +%s)"
  local epoch
  epoch="$(printf '%s' "$text" | grep -oE '\|[0-9]{10}([0-9]{3})?' | head -n1 | tr -d '|')"
  if [[ -n "$epoch" ]]; then
    if [[ ${#epoch} -gt 10 ]]; then
      epoch=$(( epoch / 1000 ))
    fi
    printf '%s' "$epoch"; return 0
  fi
  local match spec
  match="$(printf '%s' "$text" | grep -oiE 'resets?[[:space:]]+[A-Za-z]{3,9}[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m' | head -n1)"
  if [[ -n "$match" ]]; then
    spec="$(printf '%s' "$match" | sed -E 's/^[Rr]esets?[[:space:]]+//')"
    if epoch="$(_spec_to_epoch "$spec")"; then
      printf '%s' "$epoch"; return 0
    fi
  fi
  match="$(printf '%s' "$text" | grep -oiE '(resets?|reset[[:space:]]+at)[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m' | head -n1)"
  if [[ -n "$match" ]]; then
    spec="$(printf '%s' "$match" | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m')"
    if epoch="$(_spec_to_epoch "$spec")"; then
      if (( epoch <= now_epoch )); then
        epoch=$(( epoch + 86400 ))
      fi
      printf '%s' "$epoch"; return 0
    fi
  fi
  return 1
}

idle_until() {
  local target_epoch="$1"
  local now_epoch remaining chunk human
  now_epoch="$(date +%s)"
  remaining=$(( target_epoch - now_epoch ))
  if (( remaining <= 0 )); then
    return 0
  fi
  human="$(date -d "@$target_epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || date -r "$target_epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || echo "epoch $target_epoch")"
  echo "Idling until $human before resuming ($remaining seconds)..."
  while (( remaining > 0 )); do
    chunk=$(( remaining < IDLE_HEARTBEAT_SECONDS ? remaining : IDLE_HEARTBEAT_SECONDS ))
    sleep "$chunk"
    now_epoch="$(date +%s)"
    remaining=$(( target_epoch - now_epoch ))
    if (( remaining > 0 )); then
      echo "Still idling... ${remaining}s remaining until resume."
    fi
  done
  echo "Resume time reached, continuing now."
}

# Runs a single Claude invocation (fresh prompt OR resume of an existing
# session id) to completion, transparently handling usage-limit retries.
# Args: mode ("prompt"|"resume"), payload (the prompt text OR session id)
# On success, echoes the final session id captured.
run_claude_to_completion() {
  local mode="$1"
  local payload="$2"
  local sid="" new_sid="" status=0 combined_text="" reset_epoch resume_epoch
  local raw_file err_file
  local is_resume=false
  local resume_sid="$payload"

  if [[ "$mode" == "resume" ]]; then
    is_resume=true
    sid="$payload"
  fi

  while true; do
    raw_file="$(mktemp)"
    err_file="$(mktemp)"
    set +e
    if [[ "$is_resume" == true ]]; then
      echo
      echo "--- Resuming session $sid ---"
      claude -r "$sid" "Continue from the last unfinished task." \
        --output-format stream-json --verbose --include-partial-messages \
        --dangerously-skip-permissions \
        < /dev/null 2> "$err_file" \
      | tee "$raw_file" \
      | jq -j --unbuffered "$JQ_STREAM_FILTER" 2>/dev/null
    else
      claude -p "$payload" \
        --output-format stream-json --verbose --include-partial-messages \
        --dangerously-skip-permissions \
        < /dev/null 2> "$err_file" \
      | tee "$raw_file" \
      | jq -j --unbuffered "$JQ_STREAM_FILTER" 2>/dev/null
    fi
    status="${PIPESTATUS[0]}"
    set -e

    new_sid="$(jq -r '
        try (select(.session_id? != null) | .session_id) catch empty
      ' "$raw_file" 2>/dev/null | tail -n 1)"
    if [[ -n "$new_sid" ]]; then
      sid="$new_sid"
      save_session_id "$sid"
    fi

    if [[ $status -eq 0 ]]; then
      rm -f "$raw_file" "$err_file"
      printf '%s' "$sid"
      return 0
    fi

    combined_text="$(cat "$err_file" 2>/dev/null; jq -r '
        try (.result // empty) catch empty
      ' "$raw_file" 2>/dev/null)"
    rm -f "$raw_file" "$err_file"

    if is_usage_limit_error "$combined_text"; then
      echo
      echo "Usage limit hit (status $status): $combined_text"
      if ! reset_epoch="$(parse_reset_epoch "$combined_text")"; then
        echo "Could not parse an exact reset time; falling back to a ${USAGE_LIMIT_FALLBACK_WAIT}s wait."
        reset_epoch=$(( $(date +%s) + USAGE_LIMIT_FALLBACK_WAIT ))
      fi
      resume_epoch=$(( reset_epoch + RESUME_GRACE_SECONDS ))
      idle_until "$resume_epoch"
      is_resume=true
      continue
    fi

    echo
    echo "Claude exited with status $status."
    print_resume_help
    return "$status"
  done
}
