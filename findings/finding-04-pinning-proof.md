# Finding 04 — Slow Request Pins Evicted Version (Isolated Proof)

**Date:** 2026-09-13
**Stage:** 2 (Experiment B, isolated)
**Status:** Confirmed

## Setup

Single 10-second slow request against v1, followed by an immediate
swap to v2 mid-flight. NMT and per-instance gauges active.

## Trace

| Point | active{v1} | marked{v1} | evict.count |
|---|---|---|---|
| Before slow req    | 0 | 1 | 2 |
| Slow req in-flight | 1 | 1 | 2 |
| Swap to v2         | 1 | 2 | 2 |   <- marked but NOT evicted
| Slow req completes | 0 | 2 | 3 |   <- eviction fires now

## Observation

`model.evict.count` did not advance during the swap. It advanced only
after the slow request released its reference. This proves the naive
refcount defers `session.close()` for as long as any request holds a
reference — regardless of how long that is.

## Implication

Under sustained slow-request load, old versions can remain open
indefinitely. The naive design cannot bound eviction latency, and
therefore cannot bound native memory growth, without additional
lifecycle control.

## Classification

**Unbounded pinning.** Direct consequence of the refcount-as-only-
lifecycle-signal design. Distinct from the two earlier findings:
- 01 = stale map entries cause wrong swaps
- 02 = Micrometer gauge binding reuse
- 04 = pinning (this finding)