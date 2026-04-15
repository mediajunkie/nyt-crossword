# Travel Relay Plan — Print Crossword While Away

**Situation:** xian away Thu Apr 16 – Mon Apr 20. Laptop travels with him.
Briggs is home with her laptop, on the same network as the printer (192.168.4.54).

**Goal:** Crossword prints at home automatically. xian's laptop does the heavy lifting
(fetch PDF, determine puzzle type, etc.) from anywhere. Briggs' laptop is a dumb
print relay — zero developer tools required.

---

## Architecture

```
xian's laptop (hotel)              GitHub (public repo)            Briggs' laptop (home)
--------------------               --------------------            ---------------------
6:30am: script runs                                                poll-print.sh (every 5 min)
  fetch PDF via curl ✓                                               |
  try printer 192.168.4.54 ✗                                         |
  upload PDF to repo ---------> docs/pending-print.pdf               |
  set status: print-relay ----> docs/status.json                     |
                                                                  reads status.json
                                                                  sees "print-relay"
                                                                  downloads pending-print.pdf
                                                                  lpr → Brother printer ✓
                                                                  writes "printed" to a flag file
                                                                     |
                                (xian sees "relay-printed"           |
                                 on status page from Philly)         |
```

## What Goes on Briggs' Laptop

**Zero Homebrew. Zero developer tools. Only things built into macOS:**

### One script: `~/crossword-print.sh` (~25 lines)

```
curl status.json from raw GitHub URL (no auth needed, repo is public)
if status == "print-relay" and date == today and not already printed:
    curl the PDF from GitHub
    lpr to printer
    touch a flag file so we don't re-print
```

### One launchd plist: `~/Library/LaunchAgents/com.xian.crossword-print-relay.plist`

Runs `crossword-print.sh` every 300 seconds (5 min).

### Energy Saver settings

System Settings → Energy → prevent automatic sleeping when display is off.
(Or at minimum: "Wake for network access.")

### That's it. No Homebrew, no gh, no jq, no python3.

---

## What Changes on xian's Laptop / Script

### Printer reachability check

Before printing, ping the printer:

```bash
if ping -c1 -W2 192.168.4.54 &>/dev/null; then
    # local print path (existing code)
else
    # relay path: upload PDF to GitHub, set status
fi
```

### Relay upload

Upload the (possibly scaled/processed) PDF to `docs/pending-print.pdf` in the repo
via `gh api`, same pattern as `update-status.sh`. Then push status with
`status: "print-relay"`.

### Status page update

Add a new status color/state for "print-relay" — amber/blue with
"Waiting for relay..." message. Once Briggs' laptop prints, it can't easily
update status.json (no gh CLI), but the status page could show a timeout:
"Relay requested at 6:31am — check with Briggs."

(If we want confirmation, Briggs' script could curl a simple webhook or
we accept that we just trust it and verify manually.)

---

## Setup Steps

### Phase A: Changes to xian's laptop (do FIRST, before leaving)

Time estimate: ~10 min. Can be done right now.

1. **Modify `nyt-crossword.sh`**: add printer ping check + relay upload path
2. **Test relay path**: run with `--dry-run` or by temporarily making printer
   unreachable to verify it uploads to GitHub correctly
3. **Sync to `~/.local/bin/`**
4. **Commit and push**

### Phase B: Setup on Briggs' laptop (do SECOND, before leaving if time allows)

Time estimate: ~10 min with physical access.

1. **Create `~/crossword-print.sh`**:
   ```bash
   #!/bin/bash
   STATUS_URL="https://raw.githubusercontent.com/mediajunkie/nyt-crossword/main/docs/status.json"
   PDF_URL="https://raw.githubusercontent.com/mediajunkie/nyt-crossword/main/docs/pending-print.pdf"
   FLAG="$HOME/.crossword-last-printed"
   PRINTER="Brother_HL_L3270CDW_series"
   TODAY=$(date +%Y-%m-%d)

   # Only run 5am-11pm
   HOUR=$(date +%H)
   [ "$HOUR" -lt 5 ] || [ "$HOUR" -gt 22 ] && exit 0

   # Fetch status (public repo, no auth)
   STATUS=$(curl -sf "$STATUS_URL?t=$(date +%s)")
   [ -z "$STATUS" ] && exit 0

   # Check if relay print is requested for today
   S_DATE=$(echo "$STATUS" | grep -o '"date":"[^"]*"' | cut -d'"' -f4)
   S_STATUS=$(echo "$STATUS" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
   [ "$S_DATE" != "$TODAY" ] && exit 0
   [ "$S_STATUS" != "print-relay" ] && exit 0

   # Don't re-print
   [ -f "$FLAG" ] && [ "$(cat "$FLAG")" = "$TODAY" ] && exit 0

   # Download and print
   PDF="/tmp/crossword-$TODAY.pdf"
   curl -sf "$PDF_URL" -o "$PDF" || exit 1
   head -c4 "$PDF" | grep -q '%PDF' || exit 1
   lpr -P "$PRINTER" -o sides=one-sided -o fit-to-page "$PDF"
   echo "$TODAY" > "$FLAG"
   ```

2. **Make it executable**: `chmod +x ~/crossword-print.sh`

3. **Verify the printer is set up on her laptop**:
   `lpstat -p` — if Brother_HL_L3270CDW_series shows up, we're good.
   If not, add it via System Settings → Printers & Scanners.

4. **Install launchd plist** at `~/Library/LaunchAgents/com.xian.crossword-print-relay.plist`

5. **Load it**: `launchctl load ~/Library/LaunchAgents/com.xian.crossword-print-relay.plist`

6. **Energy Saver**: System Settings → Energy → prevent sleep when display is off

7. **Test**: run `~/crossword-print.sh` manually after Phase A is done to
   verify it can reach GitHub and the printer.

### Phase C: If xian runs out of time

If only Phase A is done before leaving:

- Text Briggs the steps (or leave a note)
- Steps for Briggs:
  1. Open Terminal
  2. Paste the commands xian prepares (copy-pasteable block)
  3. Done

We can prepare a SINGLE copy-paste block that creates the script, plist, loads
it, and sets energy saver — Briggs just needs to open Terminal and paste ONE thing.

---

## Rollback

When xian returns Mon Apr 20:
- The printer ping check means the script automatically goes back to local printing
- No changes needed — it just works
- Optionally unload the relay plist on Briggs' laptop (or leave it; it's harmless)

## Edge Cases

- **Sunday puzzle (Apr 19):** Script handles Sunday logic (2 pages + extra clues).
  The relay uploads the final processed PDF, so Briggs' laptop just prints whatever
  it gets. Sunday extra-clues copy: we'd need to upload that separately or combine
  into one PDF. Simplest: upload a single combined PDF with all pages.
- **Facsimile puzzle:** Scaling happens on xian's laptop before upload. Relay
  gets the ready-to-print PDF.
- **GitHub Pages cache:** Briggs' script uses raw.githubusercontent.com which
  updates faster than Pages. Add cache-buster query param.
- **Printer not found on Briggs' laptop:** She may need to add it via
  System Settings → Printers & Scanners first.
- **PDF too large for GitHub API:** The Contents API has a 100MB limit.
  Crossword PDFs are 30-900KB. Not an issue.
