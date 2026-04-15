#!/bin/bash
# =============================================================================
# ONE-TIME SETUP for Briggs' laptop as a crossword print relay.
# Open Terminal and paste this entire block.
# =============================================================================
set -euo pipefail

echo "Setting up crossword print relay..."

# 1. Create the relay print script
cat > ~/crossword-print.sh << 'SCRIPT'
#!/bin/bash
# Polls GitHub for a crossword PDF to print, then prints it.
STATUS_URL="https://raw.githubusercontent.com/mediajunkie/nyt-crossword/main/docs/status.json"
PDF_URL="https://raw.githubusercontent.com/mediajunkie/nyt-crossword/main/docs/pending-print.pdf"
FLAG="$HOME/.crossword-last-printed"
PRINTER="Brother_HL_L3270CDW_series"
TODAY=$(date +%Y-%m-%d)

# Only run 5am-11pm
HOUR=$(date +%H)
[ "$HOUR" -lt 5 ] || [ "$HOUR" -gt 22 ] && exit 0

# Fetch status (public repo, no auth needed)
STATUS=$(curl -sf "${STATUS_URL}?t=$(date +%s)" 2>/dev/null) || exit 0

# Parse JSON without jq — just grep for the fields we need
S_DATE=$(echo "$STATUS" | grep -o '"date" *: *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')
S_STATUS=$(echo "$STATUS" | grep -o '"status" *: *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')

[ "$S_DATE" != "$TODAY" ] && exit 0
[ "$S_STATUS" != "print-relay" ] && exit 0

# Don't re-print if we already printed today
[ -f "$FLAG" ] && [ "$(cat "$FLAG")" = "$TODAY" ] && exit 0

# Download and print
PDF="/tmp/crossword-${TODAY}.pdf"
curl -sf "$PDF_URL" -o "$PDF" || exit 1
head -c4 "$PDF" | grep -q '%PDF' || exit 1

lpr -P "$PRINTER" -o sides=one-sided -o fit-to-page "$PDF"
echo "$TODAY" > "$FLAG"
osascript -e 'display notification "Crossword printed!" with title "Crossword" sound name "Glass"'
SCRIPT
chmod +x ~/crossword-print.sh

# 2. Create the launchd plist (runs every 5 minutes)
cat > ~/Library/LaunchAgents/com.xian.crossword-print-relay.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.xian.crossword-print-relay</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>HOMEDIR/crossword-print.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>StandardOutPath</key>
    <string>HOMEDIR/.crossword-relay.log</string>
    <key>StandardErrorPath</key>
    <string>HOMEDIR/.crossword-relay.log</string>
</dict>
</plist>
PLIST

# Fix home directory path in plist
sed -i '' "s|HOMEDIR|$HOME|g" ~/Library/LaunchAgents/com.xian.crossword-print-relay.plist

# 3. Load the job
launchctl load ~/Library/LaunchAgents/com.xian.crossword-print-relay.plist

# 4. Check printer
echo ""
echo "Checking printer..."
if lpstat -p Brother_HL_L3270CDW_series 2>/dev/null | grep -q "idle"; then
  echo "✓ Printer found: Brother_HL_L3270CDW_series"
else
  echo "✗ Printer not found! Add it via System Settings → Printers & Scanners"
  echo "  (Look for 'Brother HL-L3270CDW series' on the network)"
fi

echo ""
echo "✓ Setup complete!"
echo "  - Poll script: ~/crossword-print.sh (runs every 5 min)"
echo "  - Log file: ~/.crossword-relay.log"
echo ""
echo "IMPORTANT: Go to System Settings → Energy and turn OFF"
echo "  'Automatically turn off display after' or set it to Never."
echo "  The laptop needs to stay awake to poll."
echo ""
echo "To test now: bash ~/crossword-print.sh"
