# Finding 07 — Experiment C After Simple Fixes 

**Date:** 2026-09-17
**Stage:** 3 (Step 3)
**Status:** Complete — Outcome A

## Purpose

Re-run Experiment C against the build containing Stage 3 Fixes 1+2
(map cleanup + gauge deregistration) to measure whether the +112 MB
retention from Finding 06 is eliminated.

## Setup

Identical to Stage 2 Experiment C:
- 8 workers, 0% slow, 120s duration
- Swap interval 300ms, ~370 swaps expected

## Results

| Metric | Stage 2 (naive) | Stage 3 (fixed) | Improvement |
|---|---|---|---|
| Requests       | 550,022 | 249,539 | — |
| Throughput     | 4,502 r/s | 1,812 r/s | see note |
| Swaps          | 353 | 369 | — |
| Errors         | 0 | 0 | — |
| WS t0 → t60    | 193 → 305 (+112) | 172 → 146 (**−26**) | **eliminated** |
| PM t0 → t60    | 262 → 376 (+114) | 219 → 231 (+13) | **88% reduction** |
| NMT t0 → t60   | 223 → 326 (+103) | 198 → 205 (+7)  | **93% reduction** |
| Post-GC drop   | −110 MB | −1 MB | **no longer needed** |

## Verdict

**Outcome A** from the Stage 3 plan's Step 4 checkpoint. The
retention defect from Finding 06 was entirely explained by the
map entry and gauge closures. Fixing the map entry alone was
sufficient; gauge deregistration is a bonus (see observation below).

The naive build required a full GC to recover 110 MB. The fixed
build never accumulates the memory in the first place.

## Secondary observations

### Fix 2 (gauge deregistration) is ineffective at the registry level

Snapshot shows:
    marked.for.eviction{version=v1} = 185.0
    marked.for.eviction{version=v2} = 184.0

Sum = 369 = evict.count. Each evicted ModelVersion's gauge is
still registered and reporting 1.0. `registry.remove(gauge)` is
either not being called or silently failing.

Memory impact: negligible (gauge objects are ~100 bytes each).
Metric impact: 370 stale registrations accumulate per minute under
aggressive cadence. Long-running process will hold thousands.

**Action:** defer investigation to Stage 3.5. Does not block Fix 3.

### Throughput drop

Throughput fell from 4502 to 1812 req/s (2.5x). Suspected cause:
dashboard controller spawning powershell/jcmd subprocesses every
2–5 seconds if the dashboard was open in a browser during the run.

**Action:** re-run Experiment C with the browser closed to isolate.
If throughput returns to Stage 2 levels, dashboard polling is the
confounder. If it stays low, the fixes have a real overhead cost.

## Files
- harness/results/stage3-expC-t0-*.txt
- harness/results/stage3-expC-t60-*.txt
- harness/results/stage3-expC-after-gc-*.txt