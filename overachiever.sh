#!/usr/bin/env bash
set -euo pipefail

TASK_FILE="${1:-tasks.txt}"
SESSION_ID_FILE="${SESSION_ID_FILE:-.claude-session-id}"
ADDITIONAL_PROMPT=""

NEW_TASK_POLL_SECONDS="${NEW_TASK_POLL_SECONDS:-5}"
NEW_TASK_POLL_ROUNDS="${NEW_TASK_POLL_ROUNDS:-3}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-task-lib.sh"

if ! command -v claude >/dev/null 2>&1; then
  echo "Error: claude command not found in PATH" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required to parse Claude's stream-json output" >&2
  exit 1
fi

if [[ ! -f "$TASK_FILE" ]]; then
  echo "Error: task file not found: $TASK_FILE" >&2
  exit 1
fi

read_all_tasks() {
  local file="$1"
  TASKS=()
  local current=""
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "${line//[[:space:]]/}" ]]; then
      if [[ -n "$current" ]]; then
        TASKS+=("$current")
        current=""
      fi
    else
      if [[ -n "$current" ]]; then
        current+=$'\n'
      fi
      current+="$line"
    fi
  done < "$file"
  if [[ -n "$current" ]]; then
    TASKS+=("$current")
  fi
}

run_task() {
  local task="$1"
  local num="$2"
  local prompt="${task} ${ADDITIONAL_PROMPT}"

  echo
  echo "============================================================"
  echo "TASK $num"
  echo "============================================================"
  printf '%s\n' "$prompt"
  echo
  echo "--- Claude output ---"

  if ! run_claude_to_completion prompt "$prompt"; then
    status=$?
    echo
    echo "Claude exited with status $status."
    echo "If this was a usage limit, wait for reset and resume later."
    print_resume_help
    exit "$status"
  fi

  echo
  echo
}

TASKS=()
task_num=0
poll_round=0

while true; do
  read_all_tasks "$TASK_FILE"
  total_tasks="${#TASKS[@]}"

  if (( task_num < total_tasks )); then
    poll_round=0
    task_num=$((task_num + 1))
    run_task "${TASKS[$((task_num - 1))]}" "$task_num"
    continue
  fi

  if (( poll_round >= NEW_TASK_POLL_ROUNDS )); then
    break
  fi

  poll_round=$((poll_round + 1))
  if (( poll_round == 1 )); then
    echo
    echo "No new tasks found. Watching $TASK_FILE for appended tasks (checking every ${NEW_TASK_POLL_SECONDS}s, ${NEW_TASK_POLL_ROUNDS} more time(s) before exiting)..."
  fi
  sleep "$NEW_TASK_POLL_SECONDS"
done

if [[ "$task_num" -eq 0 ]]; then
  echo "No tasks found in $TASK_FILE" >&2
  exit 1
fi

print_resume_help
