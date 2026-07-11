#!/usr/bin/env bash
set -euo pipefail
# resume-session.sh [session-id] [task_file] [-- extra args passed to run-tasks.sh]
#
# Use this when a previous run-tasks.sh invocation was interrupted (e.g. ran
# out of credits) and you need to finish that ONE session before the main
# script starts working through the rest of the task file. This keeps the
# "resolve stuck session" logic out of run-tasks.sh entirely.
#
# If <session-id> is omitted, it is read from SESSION_ID_FILE
# (default: .claude-session-id) instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/claude-task-lib.sh"

SESSION_ID="${1:-}"

# If no session ID was passed on the CLI, fall back to the persisted file.
if [[ -z "$SESSION_ID" ]]; then
  if [[ -f "$SESSION_ID_FILE" ]]; then
    SESSION_ID="$(cat "$SESSION_ID_FILE")"
    echo "No session ID given; using saved session from $SESSION_ID_FILE: $SESSION_ID"
  else
    echo "Error: no session ID given and $SESSION_ID_FILE not found." >&2
    echo "Usage: $0 [session-id] [task_file]" >&2
    exit 1
  fi
else
  shift
fi

if [[ -z "$SESSION_ID" ]]; then
  echo "Error: $SESSION_ID_FILE exists but is empty." >&2
  exit 1
fi

TASK_FILE="${1:-tasks.txt}"
[[ $# -gt 0 ]] && shift

echo "Resolving interrupted session: $SESSION_ID"
if final_sid="$(run_claude_to_completion resume "$SESSION_ID")"; then
  echo
  echo "Session $SESSION_ID completed successfully (final id: $final_sid)."
else
  status=$?
  echo "Failed to complete session $SESSION_ID (exit $status). Not starting main script." >&2
  exit "$status"
fi

echo
echo "Launching main task runner on $TASK_FILE..."
exec "$SCRIPT_DIR/run-tasks.sh" "$TASK_FILE" "$@"
