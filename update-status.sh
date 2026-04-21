#!/bin/bash
# =============================================================================
# update-status.sh — Push crossword run status to GitHub Pages
#
# Full update (legacy, sets top-level fields):
#   update-status.sh --date 2026-04-21 --status success --dow 2 ...
#
# Step update (merges into existing status.json):
#   update-status.sh --date 2026-04-21 --step fetch --step-status success \
#     --pdf-size 29571 --page-count 1 --puzzle-id 23889
#
#   update-status.sh --date 2026-04-21 --step print --step-status error \
#     --error "Printer unreachable"
# =============================================================================
set -uo pipefail

REPO="mediajunkie/nyt-crossword"
FILE_PATH="docs/status.json"

# --- Parse arguments ---
DATE="" STATUS="" STARTED_AT="" FINISHED_AT="" PDF_SIZE="" PAGE_COUNT=""
DOW="" PUZZLE_TYPE="" ERROR_MSG="" STEP="" STEP_STATUS="" PUZZLE_ID=""
PRINT_METHOD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --date)          DATE="$2"; shift 2 ;;
    --status)        STATUS="$2"; shift 2 ;;
    --started-at)    STARTED_AT="$2"; shift 2 ;;
    --finished-at)   FINISHED_AT="$2"; shift 2 ;;
    --pdf-size)      PDF_SIZE="$2"; shift 2 ;;
    --page-count)    PAGE_COUNT="$2"; shift 2 ;;
    --dow)           DOW="$2"; shift 2 ;;
    --puzzle-type)   PUZZLE_TYPE="$2"; shift 2 ;;
    --error)         ERROR_MSG="$2"; shift 2 ;;
    --step)          STEP="$2"; shift 2 ;;
    --step-status)   STEP_STATUS="$2"; shift 2 ;;
    --puzzle-id)     PUZZLE_ID="$2"; shift 2 ;;
    --print-method)  PRINT_METHOD="$2"; shift 2 ;;
    *)               shift ;;
  esac
done

if [[ -z "$DATE" ]]; then
  echo "ERROR: --date is required" >&2
  exit 1
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Fetch existing status.json ---
SHA=""
EXISTING_JSON="{}"
EXISTING=$(gh api "repos/$REPO/contents/$FILE_PATH" 2>/dev/null)
if [[ $? -eq 0 ]]; then
  SHA=$(echo "$EXISTING" | jq -r '.sha')
  DECODED=$(echo "$EXISTING" | jq -r '.content' | base64 --decode 2>/dev/null)
  if [[ -n "$DECODED" ]]; then
    # If the date changed, start fresh but preserve rerun fields
    EXISTING_DATE=$(echo "$DECODED" | jq -r '.date // ""')
    if [[ "$EXISTING_DATE" == "$DATE" ]]; then
      EXISTING_JSON="$DECODED"
    else
      # New day — keep only rerun fields
      EXISTING_JSON=$(echo "$DECODED" | jq '{rerun_requested_at, rerun_step}')
    fi
  fi
fi

# --- Step update mode ---
if [[ -n "$STEP" ]]; then
  if [[ -z "$STEP_STATUS" ]]; then
    echo "ERROR: --step-status is required with --step" >&2
    exit 1
  fi

  # Build the step object
  STEP_OBJ=$(jq -n \
    --arg status "$STEP_STATUS" \
    --arg at "$NOW" \
    --arg error "$ERROR_MSG" \
    --arg pdf_size "$PDF_SIZE" \
    --arg page_count "$PAGE_COUNT" \
    --arg puzzle_id "$PUZZLE_ID" \
    --arg print_method "$PRINT_METHOD" \
    '{
      status: $status,
      at: $at,
      error: (if $error == "" then null else $error end)
    }
    + (if $pdf_size != "" then {pdf_size: ($pdf_size | tonumber)} else {} end)
    + (if $page_count != "" then {page_count: ($page_count | tonumber)} else {} end)
    + (if $puzzle_id != "" then {puzzle_id: $puzzle_id} else {} end)
    + (if $print_method != "" then {method: $print_method} else {} end)
    ')

  # Merge step into existing JSON, setting top-level fields if provided
  JSON=$(echo "$EXISTING_JSON" | jq \
    --arg date "$DATE" \
    --arg step "$STEP" \
    --argjson step_obj "$STEP_OBJ" \
    --arg dow "$DOW" \
    --arg puzzle_type "$PUZZLE_TYPE" \
    --arg started_at "$STARTED_AT" \
    '. + {date: $date}
    | .[$step] = $step_obj
    | if $dow != "" then .dow = ($dow | tonumber) else . end
    | if $puzzle_type != "" then .puzzle_type = $puzzle_type else . end
    | if $started_at != "" then .started_at = $started_at else . end
    ')

# --- Legacy full update mode ---
elif [[ -n "$STATUS" ]]; then
  if [[ "$STATUS" == "success" || "$STATUS" == "error" ]] && [[ -z "$FINISHED_AT" ]]; then
    FINISHED_AT="$NOW"
  fi

  RERUN_AT=$(echo "$EXISTING_JSON" | jq '.rerun_requested_at // null')
  RERUN_STEP=$(echo "$EXISTING_JSON" | jq '.rerun_step // null')

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
    --argjson rerun_step "$RERUN_STEP" \
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
      rerun_requested_at: $rerun_requested_at,
      rerun_step: $rerun_step
    }')
else
  echo "ERROR: either --status or --step is required" >&2
  exit 1
fi

# --- Push to GitHub ---
CONTENT=$(echo "$JSON" | base64)

if [[ -n "$SHA" ]]; then
  gh api "repos/$REPO/contents/$FILE_PATH" \
    --method PUT \
    -f message="status: ${STEP:-$STATUS} for $DATE" \
    -f content="$CONTENT" \
    -f sha="$SHA" \
    --silent
else
  gh api "repos/$REPO/contents/$FILE_PATH" \
    --method PUT \
    -f message="status: ${STEP:-$STATUS} for $DATE" \
    -f content="$CONTENT" \
    --silent
fi
