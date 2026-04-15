#!/bin/bash
# =============================================================================
# update-status.sh — Push crossword run status to GitHub Pages
#
# Usage:
#   update-status.sh --date 2026-04-15 --status success \
#     --started-at "2026-04-15T06:30:00" --pdf-size 29283 \
#     --page-count 1 --dow 3 --puzzle-type weekday
#
#   update-status.sh --date 2026-04-15 --status error \
#     --started-at "2026-04-15T06:30:00" --error "NYT auth failed (HTTP 403)"
# =============================================================================
set -uo pipefail

REPO="mediajunkie/nyt-crossword"
FILE_PATH="docs/status.json"

# --- Parse arguments ---
DATE="" STATUS="" STARTED_AT="" FINISHED_AT="" PDF_SIZE="" PAGE_COUNT=""
DOW="" PUZZLE_TYPE="" ERROR_MSG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)         DATE="$2"; shift 2 ;;
    --status)       STATUS="$2"; shift 2 ;;
    --started-at)   STARTED_AT="$2"; shift 2 ;;
    --finished-at)  FINISHED_AT="$2"; shift 2 ;;
    --pdf-size)     PDF_SIZE="$2"; shift 2 ;;
    --page-count)   PAGE_COUNT="$2"; shift 2 ;;
    --dow)          DOW="$2"; shift 2 ;;
    --puzzle-type)  PUZZLE_TYPE="$2"; shift 2 ;;
    --error)        ERROR_MSG="$2"; shift 2 ;;
    *)              shift ;;
  esac
done

if [[ -z "$DATE" || -z "$STATUS" ]]; then
  echo "ERROR: --date and --status are required" >&2
  exit 1
fi

# Auto-set finished_at for terminal statuses
if [[ "$STATUS" == "success" || "$STATUS" == "error" ]] && [[ -z "$FINISHED_AT" ]]; then
  FINISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

# --- Build JSON ---
# Start with existing status.json to preserve rerun_requested_at
EXISTING_JSON=""
SHA=""
EXISTING=$(gh api "repos/$REPO/contents/$FILE_PATH" 2>/dev/null)
if [[ $? -eq 0 ]]; then
  SHA=$(echo "$EXISTING" | jq -r '.sha')
  EXISTING_JSON=$(echo "$EXISTING" | jq -r '.content' | base64 --decode 2>/dev/null)
fi

# Preserve rerun_requested_at from existing status
RERUN_AT="null"
if [[ -n "$EXISTING_JSON" ]]; then
  RERUN_AT=$(echo "$EXISTING_JSON" | jq '.rerun_requested_at // null')
fi

JSON=$(jq -n \
  --arg date "$DATE" \
  --arg status "$STATUS" \
  --arg started_at "$STARTED_AT" \
  --arg finished_at "$FINISHED_AT" \
  --arg pdf_size "$PDF_SIZE" \
  --arg page_count "$PAGE_COUNT" \
  --arg dow "$DOW" \
  --arg puzzle_type "$PUZZLE_TYPE" \
  --arg error "$ERROR_MSG" \
  --argjson rerun_requested_at "$RERUN_AT" \
  '{
    date: $date,
    status: $status,
    started_at: (if $started_at == "" then null else $started_at end),
    finished_at: (if $finished_at == "" then null else $finished_at end),
    pdf_size: (if $pdf_size == "" then null else ($pdf_size | tonumber) end),
    page_count: (if $page_count == "" then null else ($page_count | tonumber) end),
    dow: (if $dow == "" then null else ($dow | tonumber) end),
    puzzle_type: (if $puzzle_type == "" then null else $puzzle_type end),
    error: (if $error == "" then null else $error end),
    rerun_requested_at: $rerun_requested_at
  }')

# --- Push to GitHub ---
CONTENT=$(echo "$JSON" | base64)

if [[ -n "$SHA" ]]; then
  gh api "repos/$REPO/contents/$FILE_PATH" \
    --method PUT \
    -f message="status: $STATUS for $DATE" \
    -f content="$CONTENT" \
    -f sha="$SHA" \
    --silent
else
  gh api "repos/$REPO/contents/$FILE_PATH" \
    --method PUT \
    -f message="status: $STATUS for $DATE" \
    -f content="$CONTENT" \
    --silent
fi
