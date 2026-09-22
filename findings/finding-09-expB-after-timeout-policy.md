# Finding 09 — Experiment B After Timeout Policy

**Date:** 2026-09-22
**Stage:** 3 (Step 8)
**Status:** Complete

## Purpose

Re-run Stage 2's Experiment B (10% slow requests + concurrent swaps)
against the Stage 3 protocol with timeout-based forced eviction.
Compare against the naive baseline.

## Setup

Identical to Stage 2's Experiment B:
- 8 workers, 10% slow requests (5000 ms sleeps)
- Swap interval 2000 ms, 180 s duration
- No dashboard polling

## Results

| Metric | Stage 2 (naive) | Stage 3 (fixed) |
|---|---|---|
| Requests ok | 2,969 | 2,865 |
| Requests err (503) | 0 | **6** |
| Throughput | 16 req/s | 15.7 req/s |
| Swaps | 90 | 90 |
| Swap errors | 0 | 0 |
| Peak pin count | 5 | 4 |
| WS t0 → t180 | 195 → 205 (+10 MB) | 200.93 → 201.18 (**+0.25 MB**) |
| NMT committed t0 → t180 | +6 MB | +2.5 MB |

## Headline

**The bounded protocol trades unbounded pinning and +10 MB memory
growth for 6 client-visible 503s per 90 swaps (0.2% error rate).**

That's the cost of bounded memory, expressed as a single number a
production operator can reason about.

## Observations

1. **Forced evictions fired under load.** All 6 errors were HTTP 503
   with the structured retry body (`model_version_retired`).

2. **Memory is now flat.** Stage 2's naive build grew 10 MB across
   the run. The fixed build grew 0.25 MB. Fixes 1+2+3 together
   eliminate the retention drift while preserving correctness.

3. **Swap loop unaffected.** 90 swaps, 0 errors. Force-evictions on
   the inference path do not affect admin-path integrity.

4. **Pinning at peak was 4.** Consistent with 8 workers split across
   v1/v2, 10% slow. Same order as Stage 2's peak of 5, but now
   bounded in duration by T = 2000 ms rather than request duration.

5. **State drains cleanly.** At t180, both versions showed
   active=0/marked=0. No residual pinning.

## Cost model

Approximate force-evict rate:
- 90 swaps / 180 s = 0.5 swaps/sec
- 10% slow requests × 5 s = average 0.5 in-flight slow requests at any instant
- Probability a slow request is caught by a swap that then exceeds T = ~13%
- Observed: 6/90 = 6.7% of swaps triggered a force-evict

## Files
- harness/results/stage3-expB-t90-*.txt
- harness/results/stage3-expB-t180-*.txt

## Fan-out observation

4 force-evictions produced 6 client-visible 503s — meaning the
average force-evicted version had 1.5 requests in flight at the
moment the watchdog fired. The bounded-memory cost is therefore
not "one failure per swap" but "one failure per in-flight request
on a force-evicted version." Under higher concurrency (more slow
requests per version), the fan-out would scale accordingly.