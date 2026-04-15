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
#   - rmapi (brew install io41/tap/rmapi) — authenticated
#   - pypdf, reportlab, pdf2image, numpy (pip3 install pypdf reportlab pdf2image numpy)
#   - poppler (brew install poppler) — for pdf2image
#   - gh CLI (for status reporting to GitHub Pages)
#
# Usage:
#   nyt-crossword.sh              # today's puzzle
#   nyt-crossword.sh 2026-02-15   # specific date
#   nyt-crossword.sh --dry-run    # test without printing/uploading
#   nyt-crossword.sh --standard-sunday  # force standard layout + magazine handler
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

# Printer config
PRINTER_NAME="${NYT_CROSSWORD_PRINTER:-Brother_HL_L3270CDW_series}"
PRINTER_IP="192.168.4.54"

# Relay config
RELAY_REPO="mediajunkie/nyt-crossword"
RELAY_PDF_PATH="docs/pending-print.pdf"

# --- Flags ---
DRY_RUN=false
STANDARD_SUNDAY=false
TARGET_DATE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run)          DRY_RUN=true ;;
    --standard-sunday)  STANDARD_SUNDAY=true ;;
    *)                  TARGET_DATE="$arg" ;;
  esac
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

# --- Status reporting ---
push_status() {
  "$SCRIPT_DIR/update-status.sh" "$@" || true
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

die() {
  log "ERROR: $*"
  push_status --date "$TODAY" --status error --started-at "$START_TIME" --error "$*"
  notify "Crossword ✗" "$*" "Basso"
  exit 1
}

printer_reachable() {
  ping -c1 -W2 "$PRINTER_IP" &>/dev/null
}

print_pdf() {
  # Print a PDF single-sided with fit-to-page
  local file="$1"
  lpr -P "$PRINTER_NAME" -o sides=one-sided -o fit-to-page "$file"
}

relay_upload() {
  # Upload a PDF to GitHub for the relay printer to pick up
  local file="$1"
  local content
  content=$(base64 < "$file")

  # Get existing SHA if file exists
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
  # Scale an undersized PDF up to letter paper via 300dpi rasterization.
  # CUPS fit-to-page only scales DOWN; this is needed for scale-UP.
  # Only modifies the file if it's significantly smaller than letter size.
  # Returns 0 if scaled, 1 if no scaling needed.
  local file="$1"
  python3 -c "
from pypdf import PdfReader
from pdf2image import convert_from_path
from reportlab.lib.pagesizes import letter
from reportlab.pdfgen import canvas
import sys, os

LETTER_W, LETTER_H = letter  # 612, 792
TOLERANCE = 72  # 1 inch — only rasterize significantly undersized PDFs

reader = PdfReader('$file')
needs_scaling = False
for page in reader.pages:
    w = float(page.mediabox.width)
    h = float(page.mediabox.height)
    if w < (LETTER_W - TOLERANCE) or h < (LETTER_H - TOLERANCE):
        needs_scaling = True
        break

if not needs_scaling:
    sys.exit(1)  # exit 1 = no scaling needed (not an error)

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

# --- Preflight checks ---
mkdir -p "$DOWNLOAD_DIR"
command -v rmapi >/dev/null 2>&1 || die "rmapi not found. Install with: brew install io41/tap/rmapi"

# --- FETCH via curl ---
log "Fetching crossword for $TODAY..."
push_status --date "$TODAY" --status pending --started-at "$START_TIME"

COOKIE_FILE="$SCRIPT_DIR/cookies.txt"
if [[ ! -f "$COOKIE_FILE" ]]; then
  die "Cookie file not found at $COOKIE_FILE. Export NYT-S cookie from Chrome DevTools → Application → Cookies."
fi
COOKIES=$(cat "$COOKIE_FILE")

# --standard-sunday: fetch without large_print but print as Sunday magazine
if $STANDARD_SUNDAY; then
  DOW="7"  # force Sunday print path (magazine handler)
  log "Standard-Sunday mode: fetching without large_print, forcing magazine handler"
fi

# Step 1: Get puzzle ID from the metadata API
MAX_ATTEMPTS=3
PUZZLE_ID=""
for ATTEMPT in $(seq 1 $MAX_ATTEMPTS); do
  META_HTTP=$(curl -s -w '\n%{http_code}' \
    -H "Cookie: $COOKIES" \
    "https://www.nytimes.com/svc/crosswords/v6/puzzle/daily/${TODAY}.json")
  META_CODE=$(echo "$META_HTTP" | tail -1)
  META_BODY=$(echo "$META_HTTP" | sed '$d')

  if [[ "$META_CODE" == "200" ]]; then
    PUZZLE_ID=$(echo "$META_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id', d.get('puzzle_id','')))" 2>/dev/null)
    break
  elif [[ "$META_CODE" == "401" || "$META_CODE" == "403" ]]; then
    die "NYT auth failed (HTTP $META_CODE). Re-export NYT-S cookie from Chrome DevTools → Application → Cookies → nytimes.com."
  fi

  if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
    log "Metadata fetch failed (HTTP $META_CODE, attempt $ATTEMPT/$MAX_ATTEMPTS), retrying in 30s..."
    sleep 30
  fi
done

if [[ -z "$PUZZLE_ID" ]]; then
  die "Could not get puzzle ID after $MAX_ATTEMPTS attempts"
fi

# Step 2: Download the PDF
PDF_URL="https://www.nytimes.com/svc/crosswords/v2/puzzle/${PUZZLE_ID}.pdf"
if [[ "$DOW" == "7" ]] && ! $STANDARD_SUNDAY; then
  PDF_URL="${PDF_URL}?large_print=true"
fi

PDF_HTTP=$(curl -s -w '\n%{http_code}' -o "$PDF_FILE" \
  -H "Cookie: $COOKIES" \
  "$PDF_URL")
PDF_CODE=$(echo "$PDF_HTTP" | tail -1)

if [[ "$PDF_CODE" != "200" ]]; then
  die "PDF download failed (HTTP $PDF_CODE) from $PDF_URL"
fi

FETCH_SIZE=$(stat -f%z "$PDF_FILE")
log "Fetched PDF ($FETCH_SIZE bytes) from: $PDF_URL"

# Verify it's a real PDF
if ! head -c 4 "$PDF_FILE" | grep -q '%PDF'; then
  die "Downloaded file is not a valid PDF."
fi

# --- Determine puzzle type ---
PAGE_COUNT=$(python3 -c "
from pypdf import PdfReader
print(len(PdfReader('$PDF_FILE').pages))
" 2>/dev/null || echo "0")

log "PDF has $PAGE_COUNT page(s), DOW=$DOW"

# --- Determine puzzle type for status reporting ---
if [[ "$DOW" == "7" ]]; then
  if [[ "$PAGE_COUNT" -ge 2 ]]; then
    PUZZLE_TYPE="sunday"
  else
    PUZZLE_TYPE="sunday-magazine"
  fi
elif [[ "$DOW" == "6" ]]; then
  PUZZLE_TYPE="saturday"
else
  PUZZLE_TYPE="weekday"
fi

# =============================================================================
# PREPARE — process PDF for printing (scaling, Sunday clue extraction, etc.)
# Builds PRINT_FILES array: the list of PDFs to print in order.
# =============================================================================
PRINT_FILES=()

if [[ "$DOW" == "7" ]]; then
  # -----------------------------------------------------------------------
  # SUNDAY
  # -----------------------------------------------------------------------
  if [[ "$PAGE_COUNT" -ge 2 ]]; then
    # Case 3: Normal Sunday — 2 pages (grid + clues)
    # Print full PDF, then print clues page (page 2) again for second set
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
    # Case 4: Magazine Sunday — 1 page even with large_print
    PUZZLE_TYPE="sunday-magazine"
    log "Magazine-page Sunday detected (1 page) — running special handler"
    MAGAZINE_OUTPUT="$DOWNLOAD_DIR/crossword-$TODAY-magazine.pdf"

    MAGAZINE_LOG=$(python3 "$SCRIPT_DIR/magazine_sunday.py" "$PDF_FILE" "$MAGAZINE_OUTPUT" 2>&1) || true
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
        log "WARNING: Magazine output had only 1 page (clue extraction may have failed)"
        notify "Crossword ⚠" "Sunday grid prepared but clue sheet missing" "Submarine"
      fi
      PDF_FILE="$MAGAZINE_OUTPUT"
    else
      log "WARNING: magazine_sunday.py failed, using original"
      notify "Crossword ⚠" "Magazine handler failed — using original PDF" "Submarine"
      PRINT_FILES+=("$PDF_FILE")
    fi
  fi

else
  # -----------------------------------------------------------------------
  # WEEKDAY / SATURDAY
  # -----------------------------------------------------------------------
  SCALE_RESULT=$(scale_up_pdf "$PDF_FILE") && SCALED=true || SCALED=false
  if $SCALED; then
    PUZZLE_TYPE="facsimile"
    log "Scale: $SCALE_RESULT"
  elif [[ "$DOW" == "6" ]]; then
    PUZZLE_TYPE="saturday"
  else
    PUZZLE_TYPE="weekday"
  fi
  PRINT_FILES+=("$PDF_FILE")
fi

# =============================================================================
# PRINT or RELAY — send to local printer, or upload for remote relay
# =============================================================================
if $DRY_RUN; then
  log "[DRY RUN] Would print ${#PRINT_FILES[@]} file(s) to $PRINTER_NAME (DOW=$DOW, pages=$PAGE_COUNT)"
elif printer_reachable; then
  log "Printing to $PRINTER_NAME..."
  for f in "${PRINT_FILES[@]}"; do
    print_pdf "$f"
  done
  log "Printed ${#PRINT_FILES[@]} file(s) (single-sided)"
else
  log "Printer not reachable — switching to relay mode"
  # Combine all print files into one PDF for the relay
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
  push_status --date "$TODAY" --status print-relay --started-at "$START_TIME" \
    --pdf-size "$FETCH_SIZE" --page-count "$PAGE_COUNT" --dow "$DOW" \
    --puzzle-type "$PUZZLE_TYPE"
  notify "Crossword ↗" "Printer unreachable — sent to relay for Briggs" "Submarine"
fi

# --- UPLOAD TO REMARKABLE ---
if $DRY_RUN; then
  log "[DRY RUN] Would upload to reMarkable: $REMARKABLE_FOLDER"
else
  log "Uploading to reMarkable ($REMARKABLE_FOLDER)..."
  rmapi mkdir "$REMARKABLE_FOLDER" 2>/dev/null || true
  rmapi put "$PDF_FILE" "$REMARKABLE_FOLDER"
  log "Uploaded to reMarkable"
fi

# --- NOTIFY SUCCESS (only if we printed locally) ---
if ! $DRY_RUN && printer_reachable; then
  if [[ "$DOW" == "7" ]]; then
    if [[ "$PAGE_COUNT" -ge 2 ]]; then
      notify "Crossword ✓" "Sunday puzzle printed (2pp + 2x clues) and sent to reMarkable"
    else
      notify "Crossword ✓" "Magazine Sunday: grid + clue sheet printed and sent to reMarkable"
    fi
  else
    notify "Crossword ✓" "Puzzle printed and sent to reMarkable"
  fi
fi

# --- REPORT SUCCESS ---
push_status --date "$TODAY" --status success --started-at "$START_TIME" \
  --pdf-size "$FETCH_SIZE" --page-count "$PAGE_COUNT" --dow "$DOW" \
  --puzzle-type "$PUZZLE_TYPE"

# --- CLEANUP old downloads (keep 14 days) ---
find "$DOWNLOAD_DIR" -name "*.pdf" -mtime +14 -delete 2>/dev/null || true

log "Done!"
