#!/bin/bash
# =============================================================================
# NYT Crossword Daily Automation
# Downloads, prints, and sends the daily NYT crossword to reMarkable
#
# Approach: Uses curl with NYT cookies to download the crossword PDF.
# Cookie (NYT-S) must be exported from Chrome DevTools periodically.
#
# Requirements:
#   - curl
#   - cookies.txt with valid NYT-S cookie (from Chrome DevTools → Application → Cookies)
#   - rmapi — built from ddvk/rmapi master (PR #77, root-index-sort fix, merged 2026-08-18),
#     installed at ~/.local/rmapi/rmapi-sync15fix, symlinked from ~/.local/bin/rmapi.
#     Homebrew's own /opt/homebrew/bin/rmapi is left untouched — don't `brew upgrade rmapi`
#     expecting it to carry this fix until ddvk/rmapi tags a release that includes PR #77.
#     Prior fix for the same pattern: PR #56 (v4 schema fix), same install approach.
#   - pypdf, reportlab, pdf2image, numpy (pip3 install pypdf reportlab pdf2image numpy)
#   - poppler (brew install poppler) — for pdf2image
#   - gh CLI (for status reporting to GitHub Pages)
#
# Usage:
#   nyt-crossword.sh              # today's puzzle (all steps)
#   nyt-crossword.sh 2026-02-15   # specific date
#   nyt-crossword.sh --dry-run    # test without printing/uploading
#   nyt-crossword.sh --standard-sunday  # force standard layout + magazine handler
#   nyt-crossword.sh --step fetch       # only fetch PDF
#   nyt-crossword.sh --step remarkable  # only upload to reMarkable (uses existing PDF)
#   nyt-crossword.sh --step print       # only print (uses existing PDF)
#
# Puzzle cases handled:
#   1. Normal weekday/Saturday — letter-sized, 1 page → print directly
#   2. Facsimile weekday — undersized (e.g. 410x631), 1 page → scale up, print
#   3. Normal Sunday — 2 pages (grid + clues) → print all + extra clue copy
#   4. Magazine Sunday — 1 page even with large_print → crop grid + clue sheet
# =============================================================================
set -euo pipefail

# --- Configuration ---
CONFIG_DIR="$HOME/.config/nyt-crossword"
LOG_FILE="$CONFIG_DIR/crossword.log"
DOWNLOAD_DIR="$CONFIG_DIR/downloads"
REMARKABLE_FOLDER="/xwords"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Printer config — env var wins, else the name setup.sh saved, else the default
PRINTER_NAME="${NYT_CROSSWORD_PRINTER:-$(cat "$CONFIG_DIR/printer_name.txt" 2>/dev/null || echo Brother_HL_L3270CDW_series)}"
PRINTER_IP="192.168.4.54"

# Relay config
RELAY_REPO="mediajunkie/nyt-crossword"
RELAY_PDF_PATH="docs/pending-print.pdf"

# --- Flags ---
DRY_RUN=false
STANDARD_SUNDAY=false
TARGET_DATE=""
RUN_STEP=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)          DRY_RUN=true ;;
    --standard-sunday)  STANDARD_SUNDAY=true ;;
    --step)             ;; # value captured below
    fetch|remarkable|print)
      # Capture --step value (comes after --step)
      if [[ "${PREV_ARG:-}" == "--step" ]]; then
        RUN_STEP="$arg"
      else
        TARGET_DATE="$arg"
      fi ;;
    *)                  TARGET_DATE="$arg" ;;
  esac
  PREV_ARG="$arg"
done

# --- Date handling ---
if [[ -n "$TARGET_DATE" ]]; then
  DATE_STR=$(date -j -f "%Y-%m-%d" "$TARGET_DATE" +"%b%d%y")
  DOW=$(date -j -f "%Y-%m-%d" "$TARGET_DATE" +"%u")
  TODAY="$TARGET_DATE"
else
  DATE_STR=$(date +"%b%d%y")
  DOW=$(date +"%u")
  TODAY=$(date +"%Y-%m-%d")
fi
FILENAME="nyt-crossword-${TODAY}.pdf"
PDF_FILE="$DOWNLOAD_DIR/$FILENAME"
START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PUZZLE_TYPE=""
PUZZLE_ID=""
PUZZLE_TITLE=""
FETCH_SIZE=""
PAGE_COUNT=""

# --- Status reporting ---
push_step() {
  # push_step <step> <status> [extra args...]
  local step="$1" step_status="$2"
  shift 2
  "$SCRIPT_DIR/update-status.sh" --date "$TODAY" --step "$step" --step-status "$step_status" \
    --started-at "$START_TIME" --dow "$DOW" --puzzle-type "$PUZZLE_TYPE" "$@" || true
}

# --- Helper functions ---
notify() {
  local title="$1"
  local message="$2"
  local sound="${3:-Glass}"
  osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\""
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

printer_reachable() {
  # Two pings with 3s timeout — the printer often drops the first
  # packet when waking from sleep mode
  ping -c2 -W3 "$PRINTER_IP" &>/dev/null
}

print_pdf() {
  local file="$1"
  # Pre-scale to Letter before printing (Pard, 2026-07-31, Amber migration fix — Inker: see
  # docs/memo-pard-to-inker-amber-migration-2026-07-29.md). The NYT PDF is ~410x631pt; the laptop's
  # Brother VENDOR driver enlarged it Mac-side, but Amber's IPP-Everywhere queue defers scaling to
  # printer FIRMWARE, whose "fit" is shrink-only -> small inset print. Ghostscript makes the output
  # deterministic and firmware-independent. Falls back to the old path if gs is absent.
  # Scale to the printer's IMAGEABLE AREA, not the paper size. Measured from the PPD
  # (*ImageableArea Letter: 12.25 12.25 599.75 779.75) — this Brother cannot print within
  # ~12.25pt of any edge in hardware. Fitting to the full 612x792 sheet therefore clipped
  # the clue edges (2026-08-01). Two stages: fit content into an inset box, then place it
  # on Letter with a matching PageOffset. Verify changes by measuring, not by printing:
  #   gs -q -o /dev/null -sDEVICE=bbox out.pdf   -> bbox must sit inside 12.25..599.75 / 12.25..779.75
  if command -v gs >/dev/null 2>&1; then
    local staged="${file%.pdf}-fit.pdf" scaled="${file%.pdf}-letter.pdf"
    if gs -q -o "$staged" -sDEVICE=pdfwrite -dFIXEDMEDIA -dPDFFitPage \
         -dDEVICEWIDTHPOINTS=575 -dDEVICEHEIGHTPOINTS=755 "$file" 2>/dev/null \
       && gs -q -o "$scaled" -sDEVICE=pdfwrite -dFIXEDMEDIA \
            -dDEVICEWIDTHPOINTS=612 -dDEVICEHEIGHTPOINTS=792 \
            -c "<</PageOffset [18.5 18.5]>> setpagedevice" -f "$staged" 2>/dev/null \
       && [ -s "$scaled" ]; then
      file="$scaled"
    fi
  fi
  lpr -P "$PRINTER_NAME" -o sides=one-sided "$file"
}

relay_upload() {
  local file="$1"
  local content
  content=$(base64 < "$file")
  local sha
  sha=$(gh api "repos/$RELAY_REPO/contents/$RELAY_PDF_PATH" --jq '.sha' 2>/dev/null || echo "")
  local -a args=(
    --method PUT
    -f "message=print-relay: $TODAY"
    -f "content=$content"
  )
  [[ -n "$sha" ]] && args+=(-f "sha=$sha")
  gh api "repos/$RELAY_REPO/contents/$RELAY_PDF_PATH" "${args[@]}" --silent
}

scale_up_pdf() {
  local file="$1"
  python3 -c "
from pypdf import PdfReader
from pdf2image import convert_from_path
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas
import sys, os

LETTER_W, LETTER_H = letter
TOLERANCE = 72

reader = PdfReader('$file')
needs_scaling = False
for page in reader.pages:
    w = float(page.mediabox.width)
    h = float(page.mediabox.height)
    if w < (LETTER_W - TOLERANCE) or h < (LETTER_H - TOLERANCE):
        needs_scaling = True
        break

if not needs_scaling:
    sys.exit(1)

images = convert_from_path('$file', dpi=300)
tmp_dir = '/tmp/nyt-crossword-pages'
os.makedirs(tmp_dir, exist_ok=True)

c = canvas.Canvas('$file', pagesize=letter)
for i, img in enumerate(images):
    page = reader.pages[i]
    pw = float(page.mediabox.width)
    ph = float(page.mediabox.height)
    scale = min(LETTER_W / pw, LETTER_H / ph)
    content_w = pw * scale
    content_h = ph * scale
    tx = (LETTER_W - content_w) / 2
    ty = (LETTER_H - content_h) / 2
    tmp_png = f'{tmp_dir}/page{i}.png'
    img.save(tmp_png, 'PNG')
    c.drawImage(tmp_png, tx, ty, content_w, content_h)
    c.showPage()
    os.unlink(tmp_png)

c.save()
os.rmdir(tmp_dir)
print(f'Scaled {len(images)} page(s): {pw:.0f}x{ph:.0f} -> {LETTER_W:.0f}x{LETTER_H:.0f} (scale={scale:.3f}, 300dpi raster)')
" 2>&1
}

# --- Preflight ---
mkdir -p "$DOWNLOAD_DIR"

# =============================================================================
# STEP: FETCH — download the crossword PDF
# =============================================================================
do_fetch() {
  log "Fetching crossword for $TODAY..."
  push_step fetch pending

  COOKIE_FILE="$SCRIPT_DIR/cookies.txt"
  if [[ ! -f "$COOKIE_FILE" ]]; then
    push_step fetch error --error "Cookie file not found at $COOKIE_FILE"
    log "ERROR: Cookie file not found"
    return 1
  fi
  COOKIES=$(cat "$COOKIE_FILE")

  if $STANDARD_SUNDAY; then
    DOW="7"
    log "Standard-Sunday mode: fetching without large_print, forcing magazine handler"
  fi

  # Get puzzle ID from metadata API
  MAX_ATTEMPTS=3
  for ATTEMPT in $(seq 1 $MAX_ATTEMPTS); do
    META_HTTP=$(curl -s -w '\n%{http_code}' \
      -H "Cookie: $COOKIES" \
      "https://www.nytimes.com/svc/crosswords/v6/puzzle/daily/${TODAY}.json")
    META_CODE=$(echo "$META_HTTP" | tail -1)
    META_BODY=$(echo "$META_HTTP" | sed '$d')

    if [[ "$META_CODE" == "200" ]]; then
      PUZZLE_ID=$(echo "$META_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id', d.get('puzzle_id','')))" 2>/dev/null)
      # Clean puzzle title (e.g. "Big Draw") for the magazine clue sheet —
      # far more reliable than the letterspaced title in the PDF text layer.
      PUZZLE_TITLE=$(echo "$META_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('title',''))" 2>/dev/null)
      break
    elif [[ "$META_CODE" == "401" || "$META_CODE" == "403" ]]; then
      push_step fetch error --error "NYT auth failed (HTTP $META_CODE). Re-export NYT-S cookie."
      log "ERROR: NYT auth failed (HTTP $META_CODE)"
      notify "Crossword ✗" "Cookie expired — re-export NYT-S" "Basso"
      return 1
    fi

    if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
      log "Metadata fetch failed (HTTP $META_CODE, attempt $ATTEMPT/$MAX_ATTEMPTS), retrying in 30s..."
      sleep 30
    fi
  done

  if [[ -z "$PUZZLE_ID" ]]; then
    push_step fetch error --error "Could not get puzzle ID after $MAX_ATTEMPTS attempts"
    log "ERROR: Could not get puzzle ID"
    return 1
  fi

  # Download the PDF
  PDF_URL="https://www.nytimes.com/svc/crosswords/v2/puzzle/${PUZZLE_ID}.pdf"
  if [[ "$DOW" == "7" ]] && ! $STANDARD_SUNDAY; then
    PDF_URL="${PDF_URL}?large_print=true"
  fi

  PDF_HTTP=$(curl -s -w '\n%{http_code}' -o "$PDF_FILE" \
    -H "Cookie: $COOKIES" \
    "$PDF_URL")
  PDF_CODE=$(echo "$PDF_HTTP" | tail -1)

  if [[ "$PDF_CODE" != "200" ]]; then
    push_step fetch error --error "PDF download failed (HTTP $PDF_CODE)"
    log "ERROR: PDF download failed (HTTP $PDF_CODE)"
    return 1
  fi

  FETCH_SIZE=$(stat -f%z "$PDF_FILE")

  if ! head -c 4 "$PDF_FILE" | grep -q '%PDF'; then
    push_step fetch error --error "Downloaded file is not a valid PDF"
    log "ERROR: Downloaded file is not a valid PDF"
    return 1
  fi

  # Determine page count and puzzle type
  PAGE_COUNT=$(python3 -c "
from pypdf import PdfReader
print(len(PdfReader('$PDF_FILE').pages))
" 2>/dev/null || echo "0")

  if [[ "$DOW" == "7" ]]; then
    if [[ "$PAGE_COUNT" -ge 2 ]]; then PUZZLE_TYPE="sunday"
    else PUZZLE_TYPE="sunday-magazine"; fi
  elif [[ "$DOW" == "6" ]]; then PUZZLE_TYPE="saturday"
  else PUZZLE_TYPE="weekday"; fi

  log "Fetched PDF ($FETCH_SIZE bytes, $PAGE_COUNT pages, $PUZZLE_TYPE) from: $PDF_URL"
  push_step fetch success --pdf-size "$FETCH_SIZE" --page-count "$PAGE_COUNT" \
    --puzzle-id "$PUZZLE_ID" --puzzle-type "$PUZZLE_TYPE" --dow "$DOW"
}

# =============================================================================
# STEP: REMARKABLE — upload to reMarkable tablet
# =============================================================================
do_remarkable() {
  if [[ ! -f "$PDF_FILE" ]]; then
    push_step remarkable error --error "No PDF found — fetch first"
    log "ERROR: No PDF to upload to reMarkable"
    return 1
  fi

  log "Uploading to reMarkable ($REMARKABLE_FOLDER)..."
  push_step remarkable pending

  RMAPI="$HOME/.local/bin/rmapi"
  if [[ ! -x "$RMAPI" ]]; then
    push_step remarkable error --error "rmapi not found"
    log "ERROR: rmapi not found"
    return 1
  fi

  "$RMAPI" mkdir "$REMARKABLE_FOLDER" 2>/dev/null || true
  RMAPI_OUT=$("$RMAPI" put "$PDF_FILE" "$REMARKABLE_FOLDER" 2>&1) || true
  if echo "$RMAPI_OUT" | grep -q "OK\|already exists"; then
    log "Uploaded to reMarkable"
    push_step remarkable success
  else
    push_step remarkable error --error "rmapi upload failed: $RMAPI_OUT"
    log "ERROR: rmapi upload failed: $RMAPI_OUT"
    return 1
  fi
}

# =============================================================================
# STEP: PRINT — send to local printer or relay
# =============================================================================
do_print() {
  if [[ ! -f "$PDF_FILE" ]]; then
    push_step print error --error "No PDF found — fetch first"
    log "ERROR: No PDF to print"
    return 1
  fi

  push_step print pending

  # Determine page count if not already set (for --step print retries)
  if [[ -z "$PAGE_COUNT" ]]; then
    PAGE_COUNT=$(python3 -c "
from pypdf import PdfReader
print(len(PdfReader('$PDF_FILE').pages))
" 2>/dev/null || echo "0")
  fi
  if [[ -z "$DOW" ]]; then
    DOW=$(date +"%u")
  fi

  # --- Prepare print files (scaling, Sunday clue extraction) ---
  PRINT_FILES=()

  if [[ "$DOW" == "7" ]]; then
    if [[ "$PAGE_COUNT" -ge 2 ]]; then
      PUZZLE_TYPE="sunday"
      log "Normal Sunday (2+ pages)"
      PRINT_FILES+=("$PDF_FILE")

      PAGE2="$DOWNLOAD_DIR/crossword-$TODAY-clues.pdf"
      python3 -c "
from pypdf import PdfReader, PdfWriter
reader = PdfReader('$PDF_FILE')
writer = PdfWriter()
writer.add_page(reader.pages[1])
writer.write('$PAGE2')
"
      PRINT_FILES+=("$PAGE2")
      log "Prepared Sunday puzzle (2 pages + extra clues)"
    else
      PUZZLE_TYPE="sunday-magazine"
      log "Magazine-page Sunday detected (1 page) — running special handler"
      MAGAZINE_OUTPUT="$DOWNLOAD_DIR/crossword-$TODAY-magazine.pdf"

      MAGAZINE_LOG=$(python3 "$SCRIPT_DIR/magazine_sunday.py" "$PDF_FILE" "$MAGAZINE_OUTPUT" "${PUZZLE_TITLE:-}" 2>&1) || true
      log "magazine_sunday.py output: $MAGAZINE_LOG"

      if [[ -f "$MAGAZINE_OUTPUT" ]]; then
        PRINT_FILES+=("$MAGAZINE_OUTPUT")
        MAGAZINE_CLUES="$DOWNLOAD_DIR/crossword-$TODAY-magazine-clues.pdf"
        python3 -c "
from pypdf import PdfReader, PdfWriter
reader = PdfReader('$MAGAZINE_OUTPUT')
if len(reader.pages) >= 2:
    writer = PdfWriter()
    for i in range(1, len(reader.pages)):
        writer.add_page(reader.pages[i])
    writer.write('$MAGAZINE_CLUES')
"
        if [[ -f "$MAGAZINE_CLUES" ]]; then
          PRINT_FILES+=("$MAGAZINE_CLUES")
          log "Prepared magazine Sunday (grid + clue sheets)"
        else
          log "WARNING: Magazine output had only 1 page — clue extraction found no ACROSS/DOWN text."
          log "WARNING: This Sunday's PDF may carry clues as IMAGE data rather than text (observed 2026-08-02: 461 chars extracted, zero clue markers). If this recurs, the handler needs an image-crop fallback."
          DEGRADED=1
        fi
        PDF_FILE="$MAGAZINE_OUTPUT"
      else
        log "WARNING: magazine_sunday.py failed, using original"
        DEGRADED=1
        PRINT_FILES+=("$PDF_FILE")
      fi
    fi
  else
    SCALE_RESULT=$(scale_up_pdf "$PDF_FILE") && SCALED=true || SCALED=false
    if $SCALED; then
      PUZZLE_TYPE="facsimile"
      log "Scale: $SCALE_RESULT"
    fi
    PRINT_FILES+=("$PDF_FILE")
  fi

  # --- Print or relay ---
  # Try lpr directly — CUPS handles buffering/retries. Only fall back to
  # relay if lpr itself fails (e.g. printer not configured at all).
  # We previously used a ping check here, but it caused false relay triggers
  # when the printer was sleeping at 6:30am.
  log "Printing to $PRINTER_NAME..."
  LPR_OK=true
  for f in "${PRINT_FILES[@]}"; do
    if ! print_pdf "$f"; then
      LPR_OK=false
      break
    fi
  done

  if $LPR_OK; then
    log "Printed ${#PRINT_FILES[@]} file(s) (single-sided)"
    push_step print success --print-method local
    notify "Crossword ✓" "Puzzle printed" "Glass"
  else
    log "lpr failed — switching to relay mode"
    if [[ ${#PRINT_FILES[@]} -eq 1 ]]; then
      RELAY_FILE="${PRINT_FILES[0]}"
    else
      RELAY_FILE="$DOWNLOAD_DIR/crossword-$TODAY-relay.pdf"
      python3 -c "
from pypdf import PdfReader, PdfWriter
writer = PdfWriter()
for path in '''${PRINT_FILES[*]}'''.split():
    for page in PdfReader(path).pages:
        writer.add_page(page)
writer.write('$RELAY_FILE')
"
      log "Combined ${#PRINT_FILES[@]} files into relay PDF"
    fi
    relay_upload "$RELAY_FILE"
    log "Uploaded relay PDF to GitHub"
    push_step print success --print-method relay-waiting
    notify "Crossword ↗" "Printer unreachable — sent to relay" "Submarine"
  fi
}

# =============================================================================
# MAIN — run requested steps
# =============================================================================
if [[ -n "$RUN_STEP" ]]; then
  # Single step mode
  log "Running step: $RUN_STEP"
  case "$RUN_STEP" in
    fetch)      do_fetch ;;
    remarkable) do_remarkable ;;
    print)      do_print ;;
    *)          log "ERROR: Unknown step: $RUN_STEP"; exit 1 ;;
  esac
else
  # Full run — all three steps, remarkable and print are independent
  FETCH_OK=false
  if $DRY_RUN; then
    log "[DRY RUN] Would fetch, print, and upload"
    exit 0
  fi

  if do_fetch; then
    FETCH_OK=true
  else
    log "Fetch failed — skipping remarkable and print"
    notify "Crossword ✗" "Fetch failed — check status page" "Basso"
  fi

  if $FETCH_OK; then
    # Run remarkable and print independently — one failing doesn't block the other
    REMARKABLE_OK=true
    PRINT_OK=true

    do_remarkable || REMARKABLE_OK=false
    do_print || PRINT_OK=false

    if $REMARKABLE_OK && $PRINT_OK; then
      if [[ "${DEGRADED:-0}" == "1" ]]; then
  log "Done — COMPLETED WITH WARNINGS (see WARNING lines above; output is degraded, not nominal)."
else
  log "Done! All steps succeeded."
fi
    else
      $REMARKABLE_OK || log "WARNING: reMarkable upload failed"
      $PRINT_OK || log "WARNING: Print failed"
      log "Done (with warnings)."
    fi
  fi
fi

# --- CLEANUP old downloads (keep 14 days) ---
find "$DOWNLOAD_DIR" -name "*.pdf" -mtime +14 -delete 2>/dev/null || true
