# Granular Status & Per-Step Retries

## Goal

Replace the single success/error status with three independent steps, each
with its own status, timing, details, and retry action. The status page becomes
an at-a-glance dashboard that shows exactly where things stand and lets you
fix just the broken part.

---

## New Data Model: `docs/status.json`

```json
{
  "date": "2026-04-21",
  "started_at": "2026-04-21T13:35:01Z",
  "dow": 2,
  "puzzle_type": "weekday",
  "fetch": {
    "status": "success",
    "at": "2026-04-21T13:35:04Z",
    "pdf_size": 29571,
    "page_count": 1,
    "puzzle_id": "23889",
    "error": null
  },
  "remarkable": {
    "status": "success",
    "at": "2026-04-21T13:35:09Z",
    "error": null
  },
  "print": {
    "status": "success",
    "at": "2026-04-21T15:57:24Z",
    "method": "local",
    "error": null
  },
  "rerun_requested_at": null,
  "rerun_step": null
}
```

Step statuses: `"pending"`, `"success"`, `"error"`, `"skipped"`
Print method: `"local"`, `"relay-waiting"`, `"relay-printed"`

The `rerun_step` field tells the poll script which step to retry:
`"fetch"`, `"remarkable"`, `"print"`, or `"all"`.

---

## Status Page UI

### Default view — three rows, color-coded per step

```
+-------------------------------+
|  NYT Crossword                |
|  Tuesday, April 21            |
|                               |
|  [✓] Fetched         6:35am  |
|  [✓] reMarkable      6:35am  |
|  [✓] Printed         8:57am  |
|                               |
|  Updated just now             |
+-------------------------------+
```

Each row is colored:
- Green dot + text = success
- Red dot = error
- Amber pulsing dot = pending / relay-waiting
- Gray dot = skipped or not yet reached

### Tapped/expanded view — details + retry

Tapping a row expands it inline:

```
  [✗] Printed                    ←  red
      Printer unreachable
      [  Retry Print  ]          ←  button retries just this step
```

```
  [✓] Fetched          6:35am   ←  green
      Weekday · 29KB · 1pg
      Puzzle #23889
```

```
  [✗] Fetched                    ←  red
      Cookie expired (HTTP 403)
      Update NYT-S cookie, then:
      [  Retry Fetch  ]
```

### Overall status (top-level color)

The card border/background reflects the worst status:
- All green → green
- Any amber → amber
- Any red → red

---

## Script Changes: `nyt-crossword.sh`

### New flag: `--step`

```bash
nyt-crossword.sh                    # run all steps
nyt-crossword.sh --step fetch       # only fetch (and update status)
nyt-crossword.sh --step remarkable  # only upload (uses already-fetched PDF)
nyt-crossword.sh --step print       # only print (uses already-fetched PDF)
```

### Push status after EACH step

Current flow:
```
push pending → fetch → process → print → upload remarkable → push success
```

New flow:
```
push fetch=pending →
  fetch PDF →
push fetch=success →
push remarkable=pending →
  upload to remarkable →
push remarkable=success →
push print=pending →
  print (local or relay) →
push print=success
```

Each push is an incremental update — it merges into the existing status.json
rather than replacing it. This way a retry of just "print" preserves the
fetch and remarkable results.

### Step-only mode

When `--step print` is passed:
- Skip fetch (use existing PDF in downloads dir)
- Skip remarkable
- Just print, push print status

When `--step fetch` is passed:
- Fetch PDF
- Don't print or upload remarkable
- Push fetch status only

When `--step remarkable` is passed:
- Use existing PDF
- Upload to remarkable
- Push remarkable status only

---

## Changes to `update-status.sh`

Needs to support **merging** into existing status rather than replacing.

New interface:
```bash
# Full update (existing behavior, backwards compatible)
update-status.sh --date 2026-04-21 --status success ...

# Step update (new)
update-status.sh --date 2026-04-21 --step fetch --step-status success \
  --pdf-size 29571 --page-count 1 --puzzle-id 23889

update-status.sh --date 2026-04-21 --step print --step-status error \
  --error "Printer unreachable"
```

Step updates read the existing status.json and merge in the step data.

---

## Changes to Retry Mechanism

### Workflow dispatch with step parameter

`.github/workflows/rerun.yml` accepts an input:

```yaml
on:
  workflow_dispatch:
    inputs:
      step:
        description: 'Step to retry (fetch, remarkable, print, all)'
        required: false
        default: 'all'
```

Writes `rerun_step` and `rerun_requested_at` into status.json.

### Status page re-run button

Each expanded step row has its own retry button that dispatches with
the appropriate step parameter.

### poll-rerun.sh

Reads `rerun_step` and passes it to the script:
```bash
nyt-crossword.sh --step "$RERUN_STEP"
```

---

## Files to Modify

| File | Change |
|------|--------|
| `nyt-crossword.sh` | Add `--step` flag, push status after each step |
| `update-status.sh` | Support `--step` merging into existing status |
| `docs/index.html` | Three-row UI with tap-to-expand and per-step retry |
| `.github/workflows/rerun.yml` | Accept step input parameter |
| `poll-rerun.sh` | Pass step to script |

## Error Independence

Fetch failure = no PDF, so remarkable and print can't run (correct).
But remarkable and print are **independent** — one failing does not block
the other. The script attempts both regardless and reports each separately.

## Implementation Order

1. `update-status.sh` — add step-merge support
2. `nyt-crossword.sh` — add --step flag and per-step status pushes
3. `docs/index.html` — new UI
4. `.github/workflows/rerun.yml` + `poll-rerun.sh` — step-aware retries
5. Test end-to-end
6. Sync to `~/.local/bin/`
