# Inker — your Amber migration brief (pending xian's go)

**From:** Pard (Amber infrastructure lead) · **To:** Inker (crossword agent) · **cc:** xian · **Date:** 2026-07-29

Your infrastructure moved before you did: both launchd jobs now run on Amber (the always-on Mac Studio) — schedule-proven, including this morning's 06:30 end-to-end run. Your repo is cloned here; rmapi is the ddvk fork (v0.0.34, schema-v4) symlinked at your expected `~/.local/bin/rmapi`; cookies.txt is in place (refresh cadence unchanged — it's yours).

**One live issue, first task on arrival:** today's print came out at odd zoom/crop. Diagnosed: your PDF is 410×631pt; Amber's CUPS queue is IPP-Everywhere (printer-side fitting) where the laptop used Brother's vendor driver (Mac-side fitting). Pard set queue defaults `print-scaling=fit` + `media=Letter` as a likely fix — **verification is tomorrow's 06:30 print**, and if it's still off, the knobs are: the script's `-o fit-to-page` → `-o print-scaling=fit` (line 119), or installing Brother's vendor driver. Your call as maintainer; Pard's queue-layer changes are documented and reversible.

**The move itself**, when xian says go: standard protocol — write your first-person handoff (cohort shape; `one-job/docs/handoff-coral-amber-2026-07-28.md` is a good exemplar), commit+push to this repo = the standup signal; Pard provisions within minutes; account/partition per xian's call at that time. — Pard

---
## Addendum 2026-07-31 — the print-scaling saga, complete (read before touching print_pdf)

The zoom/crop weirdness took three fixes across four days; here's the whole onion so you don't re-peel it:

| Layer | Symptom | Cause | Fix |
|---|---|---|---|
| 1 (laptop era) | worked | Brother VENDOR driver scaled Mac-side | n/a — that driver isn't on Amber and isn't needed |
| 2 (Amber day 1) | weird zoom/CROP | generic IPP-Everywhere queue defers scaling to printer FIRMWARE; `-o fit-to-page` doesn't map | queue defaults `print-scaling=fit` + `media=Letter` |
| 3 (Amber day 3) | inset, huge margins | firmware's "fit" is SHRINK-ONLY — the 410×631pt NYT PDF (70% of Letter) printed at 100% centered | **current fix: `print_pdf()` pre-scales to exact Letter via ghostscript** (`gs -dFIXEDMEDIA -dPDFFitPage -dDEVICEWIDTHPOINTS=612 -dDEVICEHEIGHTPOINTS=792`) so no driver/firmware opinion survives |

State when you arrive: gs installed (`/opt/homebrew/bin/gs`, Homebrew); the pre-scale has a graceful fallback if gs vanishes; queue defaults from layer 2 are still set (harmless, now mostly moot). Verified: 2026-07-31 hand-print of the pre-scaled file. **Your verification on arrival: check one morning's print fills the page.** Do NOT install the Brother vendor driver to "fix" scaling — the deterministic pre-scale supersedes it and keeps the pipeline dependency-light. Cadence note: jobs now run under your original plists + a launchd PATH env (see repo plists); the poll job is unchanged. — Pard
