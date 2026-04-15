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

print_pdf() {
  # Print a PDF single-sided with fit-to-page
  local file="$1"
  lpr -P "$PRINTER_NAME" -o sides=one-sided -o fit-to-page "$file"
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
# PRINT — four distinct cases, no global preprocessing
# =============================================================================
if $DRY_RUN; then
  log "[DRY RUN] Would print to $PRINTER_NAME (DOW=$DOW, pages=$PAGE_COUNT)"
else
  log "Printing to $PRINTER_NAME..."

  if [[ "$DOW" == "7" ]]; then
    # -----------------------------------------------------------------------
    # SUNDAY
    # -----------------------------------------------------------------------
    if [[ "$PAGE_COUNT" -ge 2 ]]; then
      # Case 3: Normal Sunday — 2 pages (grid + clues)
      # Print full PDF, then print clues page (page 2) again for second set
      PUZZLE_TYPE="sunday"
      log "Normal Sunday (2+ pages)"
      print_pdf "$PDF_FILE"
      log "Printed full Sunday puzzle (2 pages, single-sided)"

      PAGE2="$DOWNLOAD_DIR/crossword-$TODAY-clues.pdf"
      python3 -c "
from pypdf import PdfReader, PdfWriter
reader = PdfReader('$PDF_FILE')
writer = PdfWriter()
writer.add_page(reader.pages[1])
writer.write('$PAGE2')
"
      print_pdf "$PAGE2"
      log "Printed extra clues page (page 2) — 2 sets of clues total"

    else
      # Case 4: Magazine Sunday — 1 page even with large_print
      # Run magazine_sunday.py on the ORIGINAL (untouched, vector) PDF
      # so it can extract text for clues and detect the grid visually.
      PUZZLE_TYPE="sunday-magazine"
      log "Magazine-page Sunday detected (1 page) — running special handler"
      MAGAZINE_OUTPUT="$DOWNLOAD_DIR/crossword-$TODAY-magazine.pdf"

      # Use || true to prevent set -e from killing the script if this fails
      MAGAZINE_LOG=$(python3 "$SCRIPT_DIR/magazine_sunday.py" "$PDF_FILE" "$MAGAZINE_OUTPUT" 2>&1) || true
      log "magazine_sunday.py output: $MAGAZINE_LOG"

      if [[ -f "$MAGAZINE_OUTPUT" ]]; then
        print_pdf "$MAGAZINE_OUTPUT"
        log "Printed magazine-page Sunday (grid + reformatted clues)"

        # Print ALL clue pages again for second set
        # (clues may span 2+ pages for large puzzles)
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
          print_pdf "$MAGAZINE_CLUES"
          log "Printed extra magazine clues ($((PAGE_COUNT - 1)) pages) — 2 sets of clues total"
        else
          log "WARNING: Magazine output had only 1 page (clue extraction may have failed)"
          notify "Crossword ⚠" "Sunday grid printed but clue sheet missing — check magazine_sunday.py" "Submarine"
        fi

        # Use the enhanced version for reMarkable too
        PDF_FILE="$MAGAZINE_OUTPUT"
      else
        # magazine_sunday.py failed entirely — fall back to printing the original
        log "WARNING: magazine_sunday.py failed to produce output, printing original"
        notify "Crossword ⚠" "Magazine handler failed — printing original PDF as fallback" "Submarine"
        print_pdf "$PDF_FILE"
        log "Printed magazine-page Sunday (original, fallback)"
      fi
    fi

  else
    # -----------------------------------------------------------------------
    # WEEKDAY / SATURDAY
    # -----------------------------------------------------------------------
    # Check if this is a facsimile (undersized) puzzle that needs scaling up.
    # This ONLY runs for non-Sunday puzzles — Sunday PDFs are never rasterized
    # because the magazine handler needs the original vector PDF for text
    # extraction.
    SCALE_RESULT=$(scale_up_pdf "$PDF_FILE") && SCALED=true || SCALED=false
    if $SCALED; then
      PUZZLE_TYPE="facsimile"
      log "Scale: $SCALE_RESULT"
    elif [[ "$DOW" == "6" ]]; then
      PUZZLE_TYPE="saturday"
    else
      PUZZLE_TYPE="weekday"
    fi

    print_pdf "$PDF_FILE"
    log "Printed weekday puzzle (single-sided)"
  fi
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

# --- NOTIFY SUCCESS ---
if [[ "$DOW" == "7" ]]; then
  if [[ "$PAGE_COUNT" -ge 2 ]]; then
    notify "Crossword ✓" "Sunday puzzle printed (2pp + 2x clues) and sent to reMarkable"
  else
    notify "Crossword ✓" "Magazine Sunday: grid + clue sheet printed and sent to reMarkable"
  fi
else
  notify "Crossword ✓" "Puzzle printed and sent to reMarkable"
fi

# --- REPORT SUCCESS ---
push_status --date "$TODAY" --status success --started-at "$START_TIME" \
  --pdf-size "$FETCH_SIZE" --page-count "$PAGE_COUNT" --dow "$DOW" \
  --puzzle-type "$PUZZLE_TYPE"

# --- CLEANUP old downloads (keep 14 days) ---
find "$DOWNLOAD_DIR" -name "*.pdf" -mtime +14 -delete 2>/dev/null || true

log "Done!"
