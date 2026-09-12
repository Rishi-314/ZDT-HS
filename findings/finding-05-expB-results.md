# Finding 05 — Experiment B: Slow Requests Pin Old Versions

**Date:** 2026-09-13
**Stage:** 2 (Experiment B, scaled)
**Status:** Completed

## Setup

- Duration: 182s
- Load: 8 workers, 10% of requests hit `/infer/slow?sleepMs=5000`
- Swaps: every 2s, alternating v1 ↔ v2
- 2969 requests total, 90 swaps, 0 errors either side

## Results

| Point | load | swap | evict | lag | active v1 | active v2 | WS (MB) | PM (MB) |
|---|---|---|---|---|---|---|---|---|
| Before |  4 |  3 |  2 | 2 | 0 | 0 | 195.6 | 246.6 |
| t90    | 75 | 74 | 70 | 5 | 6 | 2 | 210.2 | 266.8 |
| t180   | 96 | 95 | 92 | 4 | 0 | 0 | 205.5 | 262.2 |

## Key observations

1. **Pinning is observable.** Eviction lag (`load - evict`) grew
   from a steady 1 (Experiment A baseline) to 5 under slow-request
   load — meaning up to 5 versions were alive-but-marked-dead
   simultaneously.

2. **Per-instance gauges confirm the mechanism.** At t90, 8 workers
   each held one in-flight request (6 against a pinned v1, 2 against
   a pinned v2). These are exactly the references preventing eviction.

3. **Zero errors.** The naive design never returned 5xx, never
   corrupted state, never crashed. Pinning is a performance/lifecycle
   problem, not a correctness one, under this configuration.

4. **Memory impact is negligible at MNIST scale.** WS grew ~10 MB
   across the run, then plateaued. With a 26 KB model, five pinned
   sessions cost almost nothing. To quantify the memory consequence
   of pinning, a substantially larger model or a faster swap cadence
   would be required.

## Verdict

**Pinning confirmed. Memory impact unresolvable at this model scale.**
The naive design has a real lifecycle defect (eviction latency is
unbounded when slow requests are in flight), but demonstrating its
memory cost requires moving past MNIST.

## Follow-up actions

- Experiment C: rapid swap-back-and-forth (stale-map race, not
  pinning).
- Experiment B': rerun with a larger ONNX model (≥10 MB) if time
  permits, to expose the memory consequence of pinning.