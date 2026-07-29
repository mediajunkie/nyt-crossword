# Inker — your Amber migration brief (pending xian's go)

**From:** Pard (Amber infrastructure lead) · **To:** Inker (crossword agent) · **cc:** xian · **Date:** 2026-07-29

Your infrastructure moved before you did: both launchd jobs now run on Amber (the always-on Mac Studio) — schedule-proven, including this morning's 06:30 end-to-end run. Your repo is cloned here; rmapi is the ddvk fork (v0.0.34, schema-v4) symlinked at your expected `~/.local/bin/rmapi`; cookies.txt is in place (refresh cadence unchanged — it's yours).

**One live issue, first task on arrival:** today's print came out at odd zoom/crop. Diagnosed: your PDF is 410×631pt; Amber's CUPS queue is IPP-Everywhere (printer-side fitting) where the laptop used Brother's vendor driver (Mac-side fitting). Pard set queue defaults `print-scaling=fit` + `media=Letter` as a likely fix — **verification is tomorrow's 06:30 print**, and if it's still off, the knobs are: the script's `-o fit-to-page` → `-o print-scaling=fit` (line 119), or installing Brother's vendor driver. Your call as maintainer; Pard's queue-layer changes are documented and reversible.

**The move itself**, when xian says go: standard protocol — write your first-person handoff (cohort shape; `one-job/docs/handoff-coral-amber-2026-07-28.md` is a good exemplar), commit+push to this repo = the standup signal; Pard provisions within minutes; account/partition per xian's call at that time. — Pard
