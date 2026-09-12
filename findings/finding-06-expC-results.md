# Finding 06 — Experiment C: Aggressive Cadence Causes JVM Retention (Not Native Leak)

**Date:** 2026-09-13
**Stage:** 2 (Experiment C)
**Status:** Completed — verdict revised after GC test

## Setup

- Duration: 120s
- Swap cadence: 300ms (vs 2000ms in A/B)
- Load: 8 fast workers, ~4500 req/s
- 353 swaps, 550,022 requests, 0 errors

## Results

| Point | load | swap | evict | WS (MB) | PM (MB) | NMT (MB) |
|---|---|---|---|---|---|---|
| t0    |  96 |  95 |  92 | 193.45 | 262.09 | 223 |
| t60   | 449 | 448 | 445 | 305.46 | 376.16 | 326 |
| t120  | 449 | 448 | 445 | 301.54 | 375.45 | 326 |
| after full GC | — | — | — | **191.04** | **262.96** | **210** |

## Headline

**Growth was fully recoverable via `jcmd GC.run`.** This
disproves the initial hypothesis of an OS-level native leak.
The memory growth is JVM-side retention, not native escape.

## Mechanism

Every swap cycle:

1. `loadVersion(id)` creates a fresh ModelVersion + OrtSession.
2. `versions.put(id, newVersion)` overwrites the map entry.
3. The old ModelVersion is no longer map-reachable.
4. But **Micrometer gauges registered by the old ModelVersion
   hold weak references to lambdas capturing `this`**. As long
   as the lambda lives, the old ModelVersion is reachable.
5. In-flight requests on the old version also hold it via
   refcount until they complete.

Under normal operation GC does not aggressively collect these
weakly-reachable versions, so they accumulate. A full GC clears
them all at once.

## Why this is still a problem

1. **Monotonic growth during operation.** Experiment C's WS
   curve: 193 → 305 → 301 MB. No self-recovery observed.
2. **GC isn't guaranteed to run.** With low heap pressure, the
   JVM may not trigger a full GC for hours. The retention grows
   without bound in swap count until a full GC fires.
3. **110 MB of orphaned ModelVersions held at 353 swaps.**
   ~312 KB per evicted version. Linear in swap count.
4. **The cost scales with model size.** For a 100 MB ONNX model,
   holding even 10 old versions alive means ~1 GB of retained
   memory. MNIST at 26 KB is a "safe" case; real models aren't.

## Corrected verdict

**The naive design has unbounded JVM-side retention of evicted
model versions.** The retention is *technically* GC-recoverable,
but only via a full GC, and only after the map entry has been
overwritten by a subsequent load of the same version ID. There
is no mechanism in the code that guarantees either condition.
Under production conditions (larger models, less frequent full
GCs, longer run times) this behaves as a real leak.

## Stage 3 fixes required

1. **Explicit map cleanup on evict** — remove the versions map
   entry when a ModelVersion is marked for eviction. This alone
   would let the GC collect most orphans sooner.
2. **Explicit gauge deregistration on evict** — call
   `registry.remove(gauge)` or use a scoped MeterBinder.
3. **Consider weak references in the manager** — instead of a
   strong `ConcurrentHashMap<String, ModelVersion>`, use a
   structure that doesn't pin evicted versions.

## Note on methodology

The initial run of this experiment (without the post-GC snapshot)
was interpreted as a native leak. The GC test corrected this.
This is a useful reminder that "memory not returned during
operation" is not the same as "memory leaked at the OS level."
The right test for native leaks is exactly what we ran here:
force a GC, then measure.