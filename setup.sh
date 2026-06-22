#!/bin/bash
# =============================================================================
# NYT Crossword Automation — First-Time Setup
#
# Run this script once to install dependencies and configure everything.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$HOME/.config/nyt-crossword"
BIN_DIR="$HOME/.local/bin"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

echo "================================================"
echo "  NYT Crossword Automation — Setup"
echo "================================================"
echo ""

# --- Step 1: Create directories ---
echo "→ Creating directories..."
mkdir -p "$CONFIG_DIR/downloads"
mkdir -p "$LAUNCH_AGENTS"
echo "  ✓ Config:  $CONFIG_DIR"
echo "  ✓ Scripts: $SCRIPT_DIR (run in place)"
echo ""

# --- Step 2: Check Homebrew ---
if ! command -v brew >/dev/null 2>&1; then
  echo "⚠ Homebrew not found. Install it from https://brew.sh and re-run this script."
  exit 1
fi
echo "✓ Homebrew found"

# --- Step 3: Install rmapi ---
if command -v rmapi >/dev/null 2>&1; then
  echo "✓ rmapi already installed"
else
  echo "→ Installing rmapi..."
  brew install io41/tap/rmapi
  echo "✓ rmapi installed"
fi
echo ""

# --- Step 4: Install pypdf ---
echo "→ Checking pypdf..."
if python3 -c "import pypdf" 2>/dev/null; then
  echo "✓ pypdf already installed"
else
  echo "→ Installing pypdf..."
  pip3 install pypdf --break-system-packages 2>/dev/null || pip3 install pypdf
  echo "✓ pypdf installed"
fi
echo ""

# --- Step 5: Authenticate rmapi ---
echo "→ Checking reMarkable Cloud authentication..."
if rmapi ls / >/dev/null 2>&1; then
  echo "✓ rmapi is authenticated"
else
  echo ""
  echo "  You need to register rmapi with your reMarkable account."
  echo "  1. Go to: https://my.remarkable.com/device/browser/connect"
  echo "  2. Copy the one-time code"
  echo "  3. Enter it when prompted below"
  echo ""
  rmapi
  echo ""
fi
echo ""

# --- Step 6: Check Chrome setup ---
echo "→ Checking Chrome..."
if [[ -d "/Applications/Google Chrome.app" ]]; then
  echo "✓ Google Chrome found"
else
  echo "⚠ Google Chrome not found at /Applications/Google Chrome.app"
  exit 1
fi
echo ""
echo "  IMPORTANT: Make sure these are set in Chrome:"
echo "  1. You are logged into nytimes.com with your crossword subscription"
echo "  2. JavaScript from Apple Events is enabled:"
echo "     View → Developer → Allow JavaScript from Apple Events"
echo ""
read -rp "  Are both of these set? [Y/n] " yn
if [[ "$yn" =~ ^[Nn] ]]; then
  echo "  Please set them up and re-run this script."
  exit 1
fi
echo ""

# --- Step 7: Discover printer ---
echo "→ Looking for printers..."
echo ""
lpstat -p 2>/dev/null | while read -r line; do
  echo "  $line"
done
echo ""

BROTHER=$(lpstat -p 2>/dev/null | grep -i brother | awk '{print $2}' | head -1 || true)
if [[ -n "$BROTHER" ]]; then
  echo "  Auto-detected Brother printer: $BROTHER"
  read -rp "  Use this printer? [Y/n] " yn
  if [[ "$yn" =~ ^[Nn] ]]; then
    read -rp "  Enter printer name: " BROTHER
  fi
else
  echo "  No Brother printer auto-detected."
  echo "  (Is the laptop on the Yowlie network?)"
  read -rp "  Enter printer name (from the list above, or skip with Enter): " BROTHER
fi

if [[ -n "$BROTHER" ]]; then
  echo "$BROTHER" > "$CONFIG_DIR/printer_name.txt"
  echo "✓ Printer set to: $BROTHER"
else
  echo "⚠ No printer configured. You can set NYT_CROSSWORD_PRINTER later."
fi
echo ""

# --- Step 8: Prepare the script (runs in place from this checkout) ---
# The handler resolves its siblings (magazine_sunday.py, update-status.sh,
# cookies.txt) relative to its own directory, so it must run from the checkout
# rather than a lone copy in ~/.local/bin. The chosen printer is read from
# printer_name.txt at runtime (written above), so no script patching is needed.
echo "→ Preparing crossword script..."
chmod +x "$SCRIPT_DIR/nyt-crossword.sh"
echo "✓ Script ready at $SCRIPT_DIR/nyt-crossword.sh"
echo ""

# --- Step 9: Install launchd plist (pointed at this checkout) ---
echo "→ Installing launch agent..."
# Rewrite the template's program path to wherever this repo actually lives.
sed "s|/Users/xian/Development/nyt-crossword/nyt-crossword.sh|$SCRIPT_DIR/nyt-crossword.sh|g" \
  "$SCRIPT_DIR/com.xian.nyt-crossword.plist" > "$LAUNCH_AGENTS/com.xian.nyt-crossword.plist"

launchctl unload "$LAUNCH_AGENTS/com.xian.nyt-crossword.plist" 2>/dev/null || true
launchctl load "$LAUNCH_AGENTS/com.xian.nyt-crossword.plist"
echo "✓ Launch agent installed (runs daily at 6:30am from $SCRIPT_DIR)"
echo ""

# --- Step 10: Test run ---
echo "================================================"
echo "  Setup complete! Let's do a test run."
echo "================================================"
echo ""
read -rp "Run a dry-run test now? [Y/n] " yn
if [[ ! "$yn" =~ ^[Nn] ]]; then
  echo ""
  echo "→ Running: nyt-crossword.sh --dry-run"
  echo "---"
  bash "$BIN_DIR/nyt-crossword.sh" --dry-run
  echo "---"
  echo ""
  echo "If the download succeeded, you're all set!"
  echo ""
  read -rp "Run for real (print + send to reMarkable)? [y/N] " yn
  if [[ "$yn" =~ ^[Yy] ]]; then
    bash "$BIN_DIR/nyt-crossword.sh"
  fi
fi

echo ""
echo "================================================"
echo "  All done!"
echo ""
echo "  Daily schedule: 6:30am via launchd"
echo "  Manual run:     $SCRIPT_DIR/nyt-crossword.sh"
echo "  Dry run:        $SCRIPT_DIR/nyt-crossword.sh --dry-run"
echo "  Specific date:  $SCRIPT_DIR/nyt-crossword.sh 2026-02-15"
echo "  Logs:           $CONFIG_DIR/crossword.log"
echo "================================================"
