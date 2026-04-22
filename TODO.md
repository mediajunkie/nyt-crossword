# NYT Crossword Automation — Ideas & Backlog

## Near-term

- **Verify print actually happened (printer status check)**
  `lpr` reports success when CUPS accepts the job, not when paper comes out.
  Could query the printer via IPP/SNMP after submitting the job to check for
  errors like paper-out, toner-low, or offline. Update the print step status
  based on actual printer state, not just CUPS acceptance.

- **Finish Briggs' laptop relay setup**
  The relay mechanism works (tested during Apr 16-18 trip) but Briggs' laptop
  was never set up as a receiver. `setup-briggs.sh` is ready — just needs to
  be run on her machine via iMessage screen sharing.

- **Cookie expiration alerting**
  The status page shows the error when the cookie expires, but it would be
  nice to proactively warn a few days before expiration (if detectable) or
  at least send a push notification / email when it fails, rather than relying
  on checking the status page.

## Medium-term

- **Print confirmation on status page**
  If we can detect print success/failure via IPP, the status page could show
  "Printed (confirmed)" vs "Print sent (unconfirmed)" vs "Print failed: paper out".

- **Briggs' relay confirmation**
  When Briggs' laptop prints via relay, there's no feedback to the status page.
  Her poll script could update a simple flag file in the repo (just needs curl
  to the GitHub API with a token, or a simpler mechanism).

- **Automatic cookie refresh**
  Explore whether the NYT session can be refreshed programmatically without
  manual DevTools export. The NYT-S cookie is httpOnly so JS can't read it,
  but there may be a token refresh endpoint, or we could use a headless
  browser session periodically.

## Longer-term

- **Multiple puzzle support**
  NYT also has Mini, Spelling Bee, etc. The architecture could support
  fetching and printing other puzzle types.

- **Historical log / calendar view**
  The status page currently shows only today. A calendar view showing
  the last 30 days (green/red/gray dots) would be satisfying and useful
  for spotting patterns (e.g. "cookies expire every ~6 weeks").

- **Push notifications**
  Instead of polling the status page, send a push notification on failure.
  Could use Pushover, ntfy.sh, or a simple Shortcut/webhook to iOS.

## Completed

- ~~Status page on GitHub Pages~~ (Apr 15)
- ~~Switch from Chrome/AppleScript to curl+cookies~~ (Apr 15)
- ~~Print relay for travel~~ (Apr 15)
- ~~Granular per-step status with retries~~ (Apr 21)
