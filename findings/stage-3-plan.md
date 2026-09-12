# Stage 3 Plan — Protocol Redesign

**Date:** 2026-09-13
**System:** ZDT-HS
**Purpose:** Fix the three defects Stage 2 proved, incrementally,
re-testing after each change to preserve attribution.

---

## Defect → Fix mapping

| Stage 2 Finding | Defect | Stage 3 Fix |
|---|---|---|
| 01 (stale map swap) | `versions` map retains evicted entries | Fix 1: remove map entry on evict |
| 02 (gauge binding reuse) | Micrometer gauges never deregistered | Fix 2: `registry.remove(gauge)` on evict |
| 06 (JVM retention) | Orphan `ModelVersion` objects held via map + gauges | Fixes 1 + 2 together |
| 04 (unbounded pinning) | Eviction deferred indefinitely by in-flight requests | Fix 3: timeout-based forced eviction |

Fixes 1 and 2 are "cheap cleanup fixes" — pure housekeeping, no
semantic change. They are implemented together because their
effects on Finding 06 are inseparable (both retention paths must
be closed for the object to be collectible).

Fix 3 changes the eviction contract itself — introducing intentional
request failures as an explicit tradeoff for bounded pinning. It
is implemented and tested separately.

---

## Incremental test sequence

1. Baseline: Stage 2 numbers (naive design)
2. After Fixes 1+2: re-run Experiment C only
   → `findings/finding-07-expC-after-cheap-fixes.md`
   → Decision checkpoint: is retention now flat?
3. If retention still grows: investigate third path before
   proceeding to Fix 3
4. After Fix 3: re-run Experiment B.1 (isolated pinning proof)
   → `findings/finding-08-pinning-proof-after-timeout-policy.md`
5. Then Experiment B (scaled)
6. Then Experiment A (regression check)
7. Compile comparison table

---

## What we are explicitly NOT doing in Stage 3

- **Session pooling.** Stage 2 data showed session churn is not
  the bottleneck. Retention and pinning are. Pooling would be
  speculative optimization without evidence.
- **Hard concurrent-version cap.** Could be added later, but
  testing the timeout in isolation first means we can attribute
  its effects cleanly.
- **Any change to the swap API contract.** The `/admin/models/*`
  endpoints stay as-is. Only the internal lifecycle changes.

---

## Design decisions locked before implementation

### D1 — Map removal via callback

`ModelVersion` constructor receives a `Runnable onEvicted` that is
invoked at the end of `evict()`. Manager passes
`() -> versions.remove(versionId)`.

Rejected alternative: manager polling after `markForEviction()`
returns. Fragile — depends on manager being called again after
the last release.

### D2 — Gauge removal via direct reference

`ModelVersion` holds the two `Gauge` objects returned by
`.register()`. `evict()` calls `registry.remove(gauge)` for each
before running `onEvicted`.

Rejected alternative: `removeByPreFilterId` with a manually
reconstructed `Meter.Id`. Fiddly and version-sensitive.

### D3 — Timeout policy shape (reserved for Step 5)

Not decided yet. Depends on Step 4's checkpoint outcome. Will be
documented in `stage-3-plan.md` (this file) as an addendum before
Fix 3 is implemented.

---

## Reproducibility

Every fix gets its own snapshot series in `harness/results/`,
labeled `stage3-<fix>-<experiment>-<timepoint>`. Raw numbers
preserved exactly as in Stage 2.

---

## Files Stage 3 will produce

    findings/
      stage-3-plan.md                              (this file)
      finding-07-expC-after-cheap-fixes.md
      finding-08-pinning-proof-after-timeout-policy.md
      stage-3-summary.md

    Code changes:
      ModelVersion.java         (Gauge fields, onEvicted callback,
                                 registry.remove on evict)
      NaiveVersionManager.java  (pass callback; possibly no other
                                 change for Fixes 1+2)

    Harness additions:
      (none required for Fixes 1+2)