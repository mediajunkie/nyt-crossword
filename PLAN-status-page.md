# NYT Crossword Status Page -- Implementation Plan

## Goal

A simple, mobile-first status page (hosted on GitHub Pages) that shows whether today's crossword printed successfully, and offers a "re-run" button for transient failures. A "glance and tap" experience.

---

## Architecture

```
Mac (launchd, 6:30am)            GitHub (repo + Pages)           Phone (browser)
---------------------             ---------------------           ---------------
nyt-crossword.sh runs             status.json in repo             index.html loads
  |-- on start: push "running" ->  Pages serves index.html    ->  shows status
  |-- on success: push "success"->  + status.json              <- reads status.json
  |-- on error: push "error"   ->
  '-- done                                                        [Re-run] button
                                                                       |
                                  workflow_dispatch <------------------'
                                       |
                                  Actions job writes
                                  rerun timestamp to
                                  status.json
                                       |
Mac polls status.json (launchd)  <-- sees rerun requested
  '-- runs nyt-crossword.sh
```

**Why this design:**
- GitHub Pages is static, so the Mac must *push* status (not serve it)
- `gh api` can update a single file without git clone/push -- simple and fast
- Re-run uses `workflow_dispatch` + Mac-side polling -- no server or webhook needed
- The crossword script uses `curl` with NYT cookies (no Chrome/GUI needed), so re-runs work even when the Mac is idle

---

## Data Model: `docs/status.json`

```json
{
  "date": "2026-04-06",
  "status": "success",
  "started_at": "2026-04-06T06:30:00-07:00",
  "finished_at": "2026-04-06T06:30:25-07:00",
  "pdf_size": 29530,
  "page_count": 1,
  "dow": 1,
  "puzzle_type": "weekday",
  "error": null,
  "rerun_requested_at": null
}
```

Status values: `"pending"`, `"success"`, `"error"`

Puzzle types: `"weekday"`, `"saturday"`, `"sunday"`, `"sunday-magazine"`, `"facsimile"`

Error types worth detecting:
- `"cookie_expired"` — HTTP 401/403 from NYT API (needs manual cookie re-export)
- `"fetch_failed"` — transient network error (re-run should fix)
- `"print_failed"` — PDF ok but print submission failed
- `"other"` — unexpected errors

---

## Files to Create

| File | Purpose |
|------|---------|
| `docs/index.html` | Single-page status UI (Pages serves from `docs/`) |
| `docs/status.json` | Machine-written status data |
| `update-status.sh` | Pushes status to GitHub via `gh api` |
| `poll-rerun.sh` | Checks for rerun requests, runs the script if needed |
| `com.xian.nyt-crossword-poll.plist` | launchd job: polls every 5 min |
| `.github/workflows/rerun.yml` | workflow_dispatch handler |

## Files to Modify

| File | Change |
|------|--------|
| `nyt-crossword.sh` | Call `update-status.sh` at start, on success, and in `die()` |

---

## Phases

### Phase 1: Status Reporting (Mac -> GitHub Pages)

**1a. Git repo setup**
- Init git in the project directory
- `gh repo create nyt-crossword --private --source=.`
- Enable GitHub Pages to serve from `docs/` on `main`

**1b. Create `update-status.sh`**
- Accepts key-value args (--date, --status, --error, etc.)
- Builds JSON with `jq`
- Pushes `docs/status.json` via GitHub Contents API (`gh api repos/OWNER/REPO/contents/docs/status.json --method PUT`)
- No git clone needed -- single API call

**1c. Wire into `nyt-crossword.sh`**
- Capture `START_TIME` (ISO 8601) near top of script
- In `die()`: push status=error with error message (before `exit 1`)
- After success notification: push status=success with run details
- Derive `PUZZLE_TYPE` in each print-path branch
- Wrap status calls in `|| true` so push failures don't break the crossword job

### Phase 2: Status Page (`docs/index.html`)

Single self-contained HTML file. No build step, no framework.

**Layout (mobile):**
```
+-----------------------------+
|  NYT Crossword              |
|  Monday, April 6, 2026      |
|                              |
|  +-------------------------+ |
|  |   OK  Success           | |
|  |   6:30 -> 6:30 (25s)   | |
|  |   Weekday - 29KB - 1pg | |
|  +-------------------------+ |
|                              |
|  [ Re-run ]                  |
|                              |
|  Last checked: just now      |
+-----------------------------+
```

**Behavior:**
- Fetches `status.json` (with cache-buster query param to avoid GitHub Pages caching)
- Auto-refreshes every 30s while status is "pending"
- Color-coded: green=success, red=error, gray=pending/scheduled
- If `status.json` date is not today: "No data for today yet"
- Before 6:30am with no today data: "Scheduled for 6:30am"
- PWA meta tags + apple-mobile-web-app-capable for home screen shortcut

### Phase 3: Re-run Mechanism

**3a. GitHub Actions workflow (`.github/workflows/rerun.yml`)**
- Triggered by `workflow_dispatch`
- Writes `rerun_requested_at` timestamp into `docs/status.json`
- Commits and pushes

**3b. Re-run button in the page**
- Calls `workflow_dispatch` via GitHub API fetch()
- Needs a fine-grained PAT with `actions:write` scope on this repo only
- Token stored in localStorage on first use (page prompts once)

**3c. Mac-side polling (`poll-rerun.sh` + launchd plist)**
- Runs every 5 minutes via launchd
- Reads `status.json` via `gh api`
- If `rerun_requested_at` is newer than `finished_at`, runs the crossword script
- Writes `~/.config/nyt-crossword/last-rerun-handled` to avoid re-triggering

### Phase 4: Polish

- Error messages shown prominently on the page with actionable remediation hints
- Known-error detection and display:
  - **Cookie expired** (401/403) -> "NYT-S cookie expired. In Chrome (me profile), go to nytimes.com → DevTools → Application → Cookies → copy NYT-S value, then update cookies.txt"
  - **Fetch failed** (transient) -> show re-run button prominently
  - **Print failed** -> suggest checking printer (toner, paper, network)
- Home screen icon for iOS

---

## Implementation Order

1. Init repo, push existing code, enable Pages
2. Create `update-status.sh`, test standalone
3. Create `docs/index.html` with test data, verify on Pages
4. Wire `index.html` to read live `status.json`
5. Modify `nyt-crossword.sh` to push status -- test with `--dry-run`
6. Test end-to-end: run script, verify page updates
7. Create rerun workflow + poll script
8. Install poll launchd plist, test rerun end-to-end
9. Polish: PWA tags, error hints, home screen icon

## Known Risks / Notes

- **GitHub Pages cache:** Can be up to 10 min stale. Use cache-buster param, or fetch from raw API instead.
- **Commit churn:** ~1-2 commits/day for status updates (~700/year). Fine for a private utility repo.
- **Status push failures:** Wrapped in `|| true` -- a network outage won't break the crossword job itself.
- **Token for re-run button:** Fine-grained PAT, actions:write only, single repo. Stored in localStorage, not in the HTML source.
- **API rate limits:** Polling every 5 min = 12 calls/hour. Well within the 5,000/hour limit.
- **Cookie expiration:** NYT-S cookie expires periodically (weeks/months). This is the main manual maintenance task. The status page will detect and flag it. The cookie must be exported manually from Chrome DevTools because it's httpOnly (not accessible via document.cookie or JS).
- **Re-runs work unattended:** Since we switched from Chrome/AppleScript to curl, re-runs no longer need a GUI session. They work even when the Mac is locked or idle.

## Change Log

- **2026-04-15:** Switched fetch mechanism from Chrome/AppleScript helper app to curl + cookies. Chrome 147 broke AppleScript's ability to see windows across profiles. The curl approach is faster, simpler, and doesn't require Chrome to be running. Tradeoff: periodic manual cookie refresh needed.
