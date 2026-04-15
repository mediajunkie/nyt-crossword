#!/bin/bash
# =============================================================================
# reMarkable Virtual Printer Setup (macOS)
#
# Adds a "Print to reMarkable" option in the macOS print dialog,
# so any app can send documents to your reMarkable tablet.
# This replaces the broken "Read on reMarkable" Chrome extension.
#
# Based on: https://github.com/juruen/rmapi/blob/master/docs/tutorial-print-macosx.md
# =============================================================================

set -euo pipefail

WORKFLOW_NAME="Print to reMarkable"
WORKFLOW_DIR="$HOME/Library/PDF Services"
REMARKABLE_FOLDER="/Quick Prints"

echo "================================================"
echo "  reMarkable Virtual Printer Setup"
echo "================================================"
echo ""

# Check rmapi
if ! command -v rmapi >/dev/null 2>&1; then
  echo "⚠ rmapi not found. Run setup.sh first, or: brew install io41/tap/rmapi"
  exit 1
fi

# Check rmapi auth
if ! rmapi ls / >/dev/null 2>&1; then
  echo "⚠ rmapi not authenticated. Run 'rmapi' to set up authentication first."
  exit 1
fi

echo "✓ rmapi is installed and authenticated"
echo ""

# Create the PDF Services directory (where macOS print dialog looks for workflows)
mkdir -p "$WORKFLOW_DIR"

# Create the Automator-style shell script wrapper
# macOS print dialog passes the PDF file path as $1 when using PDF Services
cat > "$WORKFLOW_DIR/$WORKFLOW_NAME" << 'SCRIPT'
#!/bin/bash
# macOS PDF Services script — receives PDF path as argument from print dialog

PDF_PATH="$1"
REMARKABLE_FOLDER="/Quick Prints"
LOG_FILE="$HOME/.config/nyt-crossword/remarkable-printer.log"

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"
}

# Ensure PATH includes Homebrew
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [[ -z "$PDF_PATH" ]] || [[ ! -f "$PDF_PATH" ]]; then
  log "ERROR: No PDF file provided or file not found: $PDF_PATH"
  osascript -e 'display notification "No PDF file to send" with title "reMarkable" sound name "Basso"'
  exit 1
fi

log "Uploading: $PDF_PATH"

# Create folder if needed
rmapi mkdir "$REMARKABLE_FOLDER" 2>/dev/null || true

# Upload
if rmapi put "$PDF_PATH" "$REMARKABLE_FOLDER" 2>>"$LOG_FILE"; then
  BASENAME=$(basename "$PDF_PATH")
  log "Success: $BASENAME"
  osascript -e "display notification \"Sent '$BASENAME' to reMarkable\" with title \"reMarkable ✓\" sound name \"Glass\""
else
  log "ERROR: Upload failed for $PDF_PATH"
  osascript -e 'display notification "Failed to send to reMarkable" with title "reMarkable ✗" sound name "Basso"'
  exit 1
fi
SCRIPT

chmod +x "$WORKFLOW_DIR/$WORKFLOW_NAME"

echo "✓ Installed: $WORKFLOW_DIR/$WORKFLOW_NAME"
echo ""
echo "================================================"
echo "  How to use:"
echo ""
echo "  1. Open any document and press Cmd+P"
echo "  2. Click the 'PDF' dropdown in the bottom-left"
echo "  3. Select 'Print to reMarkable'"
echo "  4. The PDF will upload to your reMarkable's"
echo "     '$REMARKABLE_FOLDER' folder"
echo ""
echo "  This works in Chrome, Safari, Preview, Word,"
echo "  and any app with a print dialog."
echo "================================================"
