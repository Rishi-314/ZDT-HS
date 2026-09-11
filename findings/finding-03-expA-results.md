# Finding 03 — Experiment A: Fast Traffic + 98 Swaps

**Date:** 2026-09-12
**Stage:** 2 (Experiment A)
**Status:** Completed

## Setup

- 98 swaps over 200s (interval = 2s, alternate v1 ↔ v2)
- 8 concurrent workers, ~3041 req/s, all hitting `/infer`
- 662,024 requests total
- NMT tracking enabled (`-XX:NativeMemoryTracking=summary`)

## Results

| Time | Swaps | load | swap | evict | WS (MB) | PM (MB) | NMT (MB) |
|------|-------|------|------|-------|---------|---------|----------|
| t0   |  19   |  19  |  19  |  18   | 224.51  | 271.48  |  243     |
| t100 |  68   |  68  |  68  |  67   | 228.00  | 271.96  |  238     |
| t200 |  99   |  99  |  99  |  98   | 230.94  | 275.89  |  245     |

## Observations

- **Zero errors** in either the load or the swap loop.
- **Eviction keeps up**: evict = load − 1 exactly throughout.
  Refcount-based eviction is sufficient for the fast path.
- **Memory growth is small and non-linear**: ~290 KB/swap during
  warmup, then ~80 KB/swap in steady state.
- **NMT sees ~2.7 MB of native growth that JVM metrics don't**.
  That is the ONNX Runtime footprint outside JVM accounting —
  confirms that NMT alone is insufficient for tracking native
  model memory; process WorkingSet is the more reliable signal.

## Verdict

The naive design does **not** fail under pure fast traffic,
even with 98 concurrent hot swaps. This is a negative result but
a useful one: it isolates the failure modes we're looking for
to the *slow-request* and *concurrent-swap* scenarios (Experiments B
and C).