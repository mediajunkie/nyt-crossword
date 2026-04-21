#!/bin/bash
# =============================================================================
# poll-rerun.sh — Check GitHub for rerun requests and execute if needed
#
# Reads status.json, compares rerun_requested_at with last handled timestamp,
# and runs the appropriate step of nyt-crossword.sh if a new request is found.
# =============================================================================
set -uo pipefail

REPO="mediajunkie/nyt-crossword"
STATE_FILE="$HOME/.config/nyt-crossword/last-rerun-handled"
SCRIPT="$HOME/.local/bin/nyt-crossword.sh"
LOG_FILE="$HOME/.config/nyt-crossword/crossword.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - [poll] $*" >> "$LOG_FILE"
}

# Only poll during reasonable hours (5am - 11pm)
HOUR=$(date +%H)
if [[ "$HOUR" -lt 5 || "$HOUR" -gt 22 ]]; then
  exit 0
fi

# Fetch status.json from GitHub
STATUS=$(gh api "repos/$REPO/contents/docs/status.json" --jq '.content' 2>/dev/null | base64 --decode 2>/dev/null)
if [[ -z "$STATUS" ]]; then
  exit 0
fi

RERUN_AT=$(echo "$STATUS" | jq -r '.rerun_requested_at // empty')
if [[ -z "$RERUN_AT" ]]; then
  exit 0
fi

# Check if we already handled this request
LAST_HANDLED=""
if [[ -f "$STATE_FILE" ]]; then
  LAST_HANDLED=$(cat "$STATE_FILE")
fi

if [[ "$RERUN_AT" == "$LAST_HANDLED" ]]; then
  exit 0
fi

# Get the step to retry
RERUN_STEP=$(echo "$STATUS" | jq -r '.rerun_step // "all"')

# New rerun request — execute
log "Rerun requested at $RERUN_AT (step: $RERUN_STEP, last handled: ${LAST_HANDLED:-never})"
echo "$RERUN_AT" > "$STATE_FILE"

if [[ "$RERUN_STEP" == "all" ]]; then
  /bin/bash "$SCRIPT"
else
  /bin/bash "$SCRIPT" --step "$RERUN_STEP"
fi
