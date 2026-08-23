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

### Layer 4 (2026-08-01) — the number I should have measured first
Fitting to the **sheet** (612×792) still clipped: the PPD says `*ImageableArea Letter: 12.25 12.25 599.75 779.75` — the hardware **cannot print within ~12.25 pt of any edge**, so a page-filling PDF loses exactly that band. Now: two-stage fit into 575×755 + `PageOffset [18.5 18.5]`, verified by **measuring the output bbox** against the imageable area for BOTH input shapes (raw 410×631 and already-scaled Letter). **The standing rule for this script: verify print geometry with `gs -sDEVICE=bbox`, never by printing a page.** Four layers in five days, three of them because I reasoned about the pipeline instead of reading its numbers.

---
## Status update 2026-08-19 — closing the loop, since this sat unread for three weeks

Inker, if you're reading this now: the "standup signal" in the opening section never fired — no
handoff commit came from you, so per xian's own instruction he paces waking dormant agents
himself, I never chased it either. That's on the record now, not a silent gap.

Everything above (layers 1–4, print-scaling) held with zero regressions for three weeks — nothing
left to verify there. **One new, unrelated failure showed up 2026-08-17-19**: reMarkable's cloud
started requiring the write-path root index be sorted by document ID, which the `ddvk/rmapi`
client this repo depends on didn't do, so every upload got `400 invalid root schema` for three
straight days. Diagnosed live with xian 8/19 (ruled out quota and auth first), root-caused to
[ddvk/rmapi#76](https://github.com/ddvk/rmapi/issues/76)/[#77](https://github.com/ddvk/rmapi/pull/77)
(merged into `master` 8/18, no tagged release yet). Built from source, installed at
`~/.local/rmapi/rmapi-sync15fix` (`~/.local/bin/rmapi` symlinked there — see the updated header
comment), verified end-to-end against the real account. Fixed as of the 8/19 morning cycle; the
8/17-19 failures should not recur unless reMarkable's server-side validation changes again.

This repo is fully current — no open threads, no stale diagnosis waiting on you. If/when you do
stand up, the print pipeline and the upload path are both in a known-good, documented state. — Pard

### Layer 5 (2026-08-23) — and the general principle xian named

NYT flipped the Sunday large-print export to landscape (first time in a year of archived samples —
verified against 9 Sundays: 4 local, 5 pulled from the reMarkable cloud, all previously portrait).
The gs pipeline mishandled the rotated intermediate (content pushed past the imageable edge,
Down-clues tail hardware-clipped); fixed with pypdf portrait normalization + `-dAutoRotatePages=/None`
on both stages, verified by bbox on all three known input shapes. See the commit for mechanics.

**The durable lesson (xian's framing): the laptop-era vendor driver was an adaptive layer that
silently absorbed input variations; the deterministic pipeline that replaced it surfaces every
unhandled variation as a visible failure.** That's the better trade — today's break took minutes
to diagnose *because* the pipeline is deterministic and measurable — but it means the catalog of
input shapes is now ours to own. Expect more first-arrival breaks whenever NYT varies the export
(new page sizes, new pagination, orientation flips back), and treat each as: measure, add the
shape to the verified set, regression-check the old shapes byte-for-byte. Never "fix" by
reinstalling the adaptive layer — that just trades visible, diagnosable failures for silent,
undiagnosable ones.
