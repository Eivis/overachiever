#!/usr/bin/env bash
set -euo pipefail
# -e: exit on any command failure
# -u: error on unset variables
# -o pipefail: a pipeline fails if any stage fails, not just the last one

# First CLI arg is the task file, defaults to tasks.txt if not given
TASK_FILE="${1:-tasks.txt}"
# Where we persist the last known Claude session ID (overridable via env var)
SESSION_ID_FILE="${SESSION_ID_FILE:-.claude-session-id}"
# Optional Additional prompt text that should be passed to all tasks
ADDITIONAL_PROMPT=""

# How long to wait after the reported reset time before resuming (default 60s)
RESUME_GRACE_SECONDS="${RESUME_GRACE_SECONDS:-60}"
# If we hit a usage limit but can't parse an exact reset time, wait this long
# before retrying (default 5 hours, matching Claude's rolling session window)
USAGE_LIMIT_FALLBACK_WAIT="${USAGE_LIMIT_FALLBACK_WAIT:-18000}"
# How often (seconds) to print a heartbeat while idling
IDLE_HEARTBEAT_SECONDS="${IDLE_HEARTBEAT_SECONDS:-300}"

# --- Preflight checks ---

# Make sure the claude CLI is installed and on PATH
if ! command -v claude >/dev/null 2>&1; then
  echo "Error: claude command not found in PATH" >&2
  exit 1
fi

# jq is needed to parse the stream-json NDJSON output (extract text + session_id)
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to parse Claude's stream-json output" >&2
  exit 1
fi

# Confirm the task file actually exists before we try to read it
if [[ ! -f "$TASK_FILE" ]]; then
  echo "Error: task file not found: $TASK_FILE" >&2
  exit 1
fi

# The jq filter used to render Claude's stream-json output as readable text.
# Shared by both the initial run and any resume attempts.
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

# --- Helper functions ---

# Persist a session ID to disk so it can be reused later for --resume/-r
save_session_id() {
  local sid="$1"
  if [[ -n "$sid" ]]; then
    printf '%s\n' "$sid" > "$SESSION_ID_FILE"
  fi
}

# Print instructions for resuming, using the last saved session ID if available
print_resume_help() {
  local sid=""
  if [[ -f "$SESSION_ID_FILE" ]]; then
    sid="$(cat "$SESSION_ID_FILE")"
  fi

  echo
  echo "Resume later with one of these:"
  if [[ -n "$sid" ]]; then
    # We know the exact session ID, so give the most specific resume commands
    echo "  claude -r \"$sid\""
    echo "  claude --resume \"$sid\""
    echo "  claude -c"
  else
    # No session ID captured, fall back to generic guidance
    echo "  claude -c"
    echo "  claude --resume <session-id>"
  fi
  echo
}

# Decide whether a failure looks like a plan usage-limit lockout (as opposed
# to an auth error, server error, bad request, etc.) based on Claude's own
# error text (stderr + any "result" text captured from the JSON stream).
is_usage_limit_error() {
  local text="$1"
  # Explicitly NOT a usage limit (Claude's own wording for a transient throttle)
  if printf '%s' "$text" | grep -qiE 'not your usage limit'; then
    return 1
  fi
  printf '%s' "$text" | grep -qiE \
    '(usage|session|weekly|opus)[[:space:]]+limit[[:space:]]+(reached|exceeded)|hit[[:space:]]+(your|the)[[:space:]]+(session|weekly|usage)[[:space:]]+limit|usage[[:space:]]+limit[[:space:]]+reached\|[0-9]+'
}

# Convert a human time spec like "3:45pm" or "Mon 12:00am" into epoch seconds.
# Tries GNU date, then gdate (macOS w/ coreutils), then BSD date as a fallback.
_spec_to_epoch() {
  local spec="$1"
  local epoch=""

  if epoch="$(date -d "$spec" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
    return 0
  fi

  if command -v gdate >/dev/null 2>&1 && epoch="$(gdate -d "$spec" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
    return 0
  fi

  local compact
  compact="$(printf '%s' "$spec" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  if epoch="$(date -j -f "%I:%M%p" "$compact" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
    return 0
  fi
  if epoch="$(date -j -f "%I%p" "$compact" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
    return 0
  fi

  return 1
}

# Try to find the epoch this task's usage window resets at, based on Claude's
# error text. Supports:
#   1. "...usage limit reached|1755615600"  (machine-readable unix epoch)
#   2. "...resets Mon 12:00am"              (weekly limit, day + time)
#   3. "...resets 3:45pm" / "resets 3pm"    (session limit, time only -> today/tomorrow)
# Prints the epoch on success, returns 1 if nothing could be parsed.
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
    printf '%s' "$epoch"
    return 0
  fi

  local match spec
  match="$(printf '%s' "$text" | grep -oiE 'resets?[[:space:]]+[A-Za-z]{3,9}[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m' | head -n1)"
  if [[ -n "$match" ]]; then
    spec="$(printf '%s' "$match" | sed -E 's/^[Rr]esets?[[:space:]]+//')"
    if epoch="$(_spec_to_epoch "$spec")"; then
      printf '%s' "$epoch"
      return 0
    fi
  fi

  match="$(printf '%s' "$text" | grep -oiE '(resets?|reset[[:space:]]+at)[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m' | head -n1)"
  if [[ -n "$match" ]]; then
    spec="$(printf '%s' "$match" | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m')"
    if epoch="$(_spec_to_epoch "$spec")"; then
      if (( epoch <= now_epoch )); then
        epoch=$(( epoch + 86400 ))
      fi
      printf '%s' "$epoch"
      return 0
    fi
  fi

  return 1
}

# Sleep (in heartbeat-sized chunks, so progress is visible) until the target
# epoch is reached.
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

# Runs a single task through Claude, streams readable output live, and tries
# to capture the session ID for later resumption. If Claude hits a plan usage
# limit mid-task, this idles until 1 minute after the reported reset time and
# then automatically resumes the *same* interrupted session, rather than
# exiting the script. Any other kind of failure still aborts as before.
run_task() {
  local task="$1"
  local num="$2"
  local prompt="${task} ${ADDITIONAL_PROMPT}"
  local raw_file err_file
  local sid=""
  local new_sid=""
  local status=0
  local is_resume=false
  local combined_text=""
  local reset_epoch resume_epoch

  echo
  echo "============================================================"
  echo "TASK $num"
  echo "============================================================"
  printf '%s\n' "$prompt"
  echo
  echo "--- Claude output ---"

  while true; do
    raw_file="$(mktemp)"
    err_file="$(mktemp)"

    # Temporarily disable -e so a nonzero Claude exit code doesn't kill the
    # script here; we want to handle the failure ourselves below.
    set +e
    if [[ "$is_resume" == true && -n "$sid" ]]; then
      echo
      echo "--- Resuming interrupted session $sid ---"
      claude -r "$sid" "Continue from the last unfinished task." \
        --output-format stream-json \
        --verbose \
        --include-partial-messages \
        --dangerously-skip-permissions \
        < /dev/null 2> "$err_file" \
      | tee "$raw_file" \
      | jq -j --unbuffered "$JQ_STREAM_FILTER" 2>/dev/null
    else
      claude -p "$prompt" \
        --output-format stream-json \
        --verbose \
        --include-partial-messages \
        --dangerously-skip-permissions \
        < /dev/null 2> "$err_file" \
      | tee "$raw_file" \
      | jq -j --unbuffered "$JQ_STREAM_FILTER" 2>/dev/null
    fi
    # Capture Claude's own exit code (first stage of the pipeline), not tee/jq's
    status="${PIPESTATUS[0]}"
    set -e

    # Always try to capture and save the session ID first, whether or not the
    # task succeeded. The "system init" event (which contains session_id) is
    # emitted at the very start of the stream, so it's usually present even
    # when the task fails partway through (e.g. a usage limit).
    new_sid="$(jq -r '
        try (select(.session_id? != null) | .session_id) catch empty
      ' "$raw_file" 2>/dev/null | tail -n 1)"
    if [[ -n "$new_sid" ]]; then
      sid="$new_sid"
      save_session_id "$sid"
    fi

    if [[ $status -eq 0 ]]; then
      rm -f "$raw_file" "$err_file"
      break
    fi

    # Gather error text from both stderr and any "result" text in the JSON
    # stream, since usage-limit messages can show up in either place.
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

    # Not a usage-limit issue (auth error, bad request, etc.) — abort as before
    echo
    echo "Claude exited with status $status."
    echo "If this was a usage limit, wait for reset and resume later."
    print_resume_help
    exit "$status"
  done

  echo
  echo
}

# --- Main task-parsing loop ---
# Tasks in the file are separated by blank lines; each block becomes one task

task_num=0
current_task=""

while IFS= read -r line <&3 || [[ -n "$line" ]]; do
  if [[ -z "${line//[[:space:]]/}" ]]; then
    # Blank (or whitespace-only) line = end of current task block
    if [[ -n "$current_task" ]]; then
      task_num=$((task_num + 1))
      run_task "$current_task" "$task_num"
      current_task=""
    fi
  else
    # Non-blank line = part of the current task; append with a newline separator
    if [[ -n "$current_task" ]]; then
      current_task+=$'\n'
    fi
    current_task+="$line"
  fi
done 3< "$TASK_FILE"

# Handle a trailing task that wasn't followed by a final blank line
if [[ -n "$current_task" ]]; then
  task_num=$((task_num + 1))
  run_task "$current_task" "$task_num"
fi

# If the file was empty or had no valid tasks, fail loudly
if [[ "$task_num" -eq 0 ]]; then
  echo "No tasks found in $TASK_FILE" >&2
  exit 1
fi

# All tasks done — show how to resume the last Claude session if needed
print_resume_help
