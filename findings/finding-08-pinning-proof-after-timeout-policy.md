# Finding 08 — Pinning Bounded by Timeout Policy

**Date:** 2026-09-22
**Stage:** 3 (Step 7)
**Status:** Complete

## Purpose

Re-run Stage 2's isolated pinning proof (Finding 04) against the
Stage 3 protocol with timeout-based forced eviction (T = 2000 ms,
watchdog sweep interval = 1000 ms).

## Before (Finding 04, naive build)

| Point | active v1 | marked v1 | evict |
|---|---|---|---|
| Before | 0 | 0 | 2 |
| In-flight | 1 | 0 | 2 |
| Swap | 1 | 1 | 2 |
| Slow req finishes (10s) | 0 | 1 | 3 |
| Request result | **10 floats returned** | | |

- Pinning duration: **10 seconds** (full sleep)
- Outcome: silent success

## After (Finding 08, Stage 3 protocol)

| Point | active v1 | marked v1 | evict | forced |
|---|---|---|---|---|
| Before | 0 | 0 | 4 | 2 |
| T=1s, in-flight | 1 | 0 | 4 | 2 |
| Swap to v2 (≈1s) | 1 | 1 | 4 | 2 |
| T=2s (sweep 1) | 1 | 1 | 4 | 2 |
| T=3s (sweep 2) | 0 | 1 | 4 | **3** |
| Request returns | — | — | 4 | 3 |

- Pinning duration: **~2 seconds** (bounded by T + sweep jitter)
- Outcome: **HTTP 503** with structured retry hint

## Verdict

Bounded pinning achieved. Session close fires within
T + watchdog_sweep_interval of a version being marked. The
`model.forced.evict.count` counter increments, `model.evict.count`
does not — the two paths are distinctly measured.

## Nuance — resource bounds differ

The timeout bounds **memory** pinning (session closed, native
resources released, JVM object eligible for GC) but does not
bound **thread** pinning. In-flight request threads are not
interrupted by `session.close()`. A request sleeping for 10
seconds still holds its Tomcat worker for the full 10 seconds,
even though the session was closed at T=2s. The client receives
a 503 only after the request's own blocking work finishes.

For real inference workloads, this is immaterial: `session.run()`
fails fast (milliseconds) on a closed session, so the thread is
freed almost immediately. Our `/infer/slow` endpoint is a
synthetic test harness that deliberately blocks; it overstates
the thread-pinning cost.

## Bound summary

| Resource | Bounded by T? | Practical bound |
|---|---|---|
| Native session memory | Yes | T + sweep interval |
| ModelVersion object | Yes | T + sweep interval |
| Tomcat worker thread | No | full request duration |
| Client-observed latency | No | full request duration |

The memory bound is the property that matters for hot-swap safety.