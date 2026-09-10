# Finding 01 — Stale Version Reference After Swap-Back Causes 500

**Date:** 2026-09-10
**Stage:** 0 (Baseline)
**Status:** Confirmed, reproducible

## Summary

In the naive `NaiveVersionManager`, once a model version is evicted
(its `OrtSession` closed via `markForEviction` → `evict`), the entry
for that version remains in the `versions` ConcurrentHashMap.
Subsequent `swapTo(versionId)` calls only check `containsKey`, not
session validity, so the system happily accepts a swap to a dead
version. The next `/infer` call returns HTTP 500.

## Reproduction

1. Start app (auto-loads v1, swaps to v1)
2. `POST /admin/models/load?versionId=v2&path=...`
3. `POST /admin/models/swap?versionId=v2`   → v1 marked for eviction, session closed
4. `POST /admin/models/swap?versionId=v1`   → returns "Swapped to version: v1" (WRONG)
5. `POST /infer` with 784-float body        → 500 Internal Server Error

## Expected

Step 4 should either:
- return an error ("Version v1 has been evicted; reload required"), OR
- transparently reload v1 from disk under the same version ID.

## Actual

Step 4 succeeds silently. Step 5 fails with HTTP 500
(`IllegalStateException: Session is closed` in the app log).

## Metric state at failure

- `model.evict.count`               = 1.0
- `model.version.marked.for.eviction{version=v1}` = 1.0
- `model.version.active.requests{version=v2}`     = 0.0

## Root cause

`NaiveVersionManager.swapTo()` validates existence via
`versions.containsKey(versionId)` but does not validate liveness.
`ModelVersion.markForEviction()` sets a flag and closes the session
but does not remove the entry from the map.

## Classification

**Version-map staleness bug.**
Distinct from the memory-leak finding (see finding-02), which covers:
- the map entry never being removed,
- the per-version Micrometer gauges never being deregistered,
- native ONNX session memory not being guaranteed to be released
  at the OS level after `session.close()`.

## Stage 3 fix direction (not implemented yet)

`swapTo` must check `version.isMarkedForEviction()` (or a new
`isAlive()` method) and either reject or reload. The map should also
be cleaned up on eviction.