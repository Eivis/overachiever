Here's the updated, simplified README for `overachiever.sh`, reflecting the new usage-limit auto-recovery and live task-polling behavior.[1]

# Overachiever

A bash script that runs a batch of Claude Code tasks one after another, automatically waits out usage limits, and picks up new tasks appended while it's running.

## Requirements

- `claude` CLI installed and available on your `PATH`
- `jq` installed (used to parse Claude's streaming JSON output)
- A task file (default: `tasks.txt`) containing your tasks

## Quickstart

```bash
# 1. Make the script executable
chmod +x overachiever.sh

# 2. Create a task file, one task per block, separated by blank lines

# 3. Run it
./overachiever.sh tasks.txt
```

That's it — the script runs each task through Claude, streams the output live, and moves to the next one automatically.

## Task File Format

Each task is a block of text. Blocks are separated by a blank line:

```
Task one description, can span
multiple lines

Task two description
```

## Usage

```bash
./overachiever.sh [task_file]
```

- `task_file` (optional) — defaults to `tasks.txt` if not given.

## What It Does

1. Checks that `claude` and `jq` are installed, and that the task file exists.
2. Reads the task file and runs each task through `claude -p`, streaming live output.
3. Saves the Claude session ID after each task to `.claude-session-id`.
4. If Claude hits a usage limit mid-task, the script automatically waits until the limit resets, then resumes the same session — no manual restart needed.
5. After finishing all known tasks, it briefly polls the task file for newly appended tasks before exiting, so you can add more tasks while it's running.

## Resuming Manually

If the script exits for a non-usage-limit error, resume with:

```bash
claude -r "<session-id>"
# or
claude --resume "<session-id>"
# or simply
claude -c
```

The session ID is read automatically from `.claude-session-id` if present.

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `SESSION_ID_FILE` | Where the last session ID is stored | `.claude-session-id` |
| `RESUME_GRACE_SECONDS` | Extra buffer after the reset time before resuming | `60` |
| `USAGE_LIMIT_FALLBACK_WAIT` | Wait time if an exact reset time can't be parsed | `18000` (5 hours) |
| `IDLE_HEARTBEAT_SECONDS` | How often to print an idling heartbeat | `300` |
| `NEW_TASK_POLL_SECONDS` | Seconds between polls for new tasks | `5` |
| `NEW_TASK_POLL_ROUNDS` | How many times to poll before exiting | `3` (set `0` to disable) |

## Notes

- Runs with `--dangerously-skip-permissions`, so Claude won't prompt for tool-use approval — use only in trusted environments.
- If the task file is empty or has no valid tasks, the script exits with an error.

Sources
[1] claude-task-automation.txt https://ppl-ai-file-upload.s3.amazonaws.com/web/direct-files/collection_aa536982-b9f3-4e21-b3be-258a13ca76c2/05e35d04-6731-48c0-bde5-8b37e78b9d57/claude-task-automation.txt
