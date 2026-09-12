# Stage 2 Summary — Stress Testing the Naive Hot-Swap Design

**Date:** 2026-09-13
**System:** ZDT-HS (Spring Boot 4.0.8, Java 26, ONNX Runtime 1.19.2)
**Purpose:** Systematically break the naive hot-swap design under
controlled stress, and produce quantitative evidence of its failure
modes.

---

## 1. Purpose and scope

Stage 0 produced a working hot-swap system. Stage 1 instrumented it
with Micrometer counters and gauges and enabled Native Memory
Tracking. Stage 2 was a deliberate attempt to make that system fail —
under load, under swap churn, and under mixed request profiles — and
to capture each failure mode as a measurable, reproducible result.

This document is the canonical Stage 2 record. It should be treated
as the primary data source for the paper's "Experimental Results"
section. Each numbered finding below corresponds to a separate
`findings/finding-XX-*.md` file with the raw trace.

---

## 2. Instrumentation added in Stage 2

### 2.1 Native Memory Tracking

Added to `pom.xml` under `spring-boot-maven-plugin`:

    -XX:NativeMemoryTracking=summary

Queried with `jcmd <PID> VM.native_memory summary`. Provides
"Total committed" as the primary native memory metric.

### 2.2 Swap guard

Added `isAlive()` to `ModelVersion` (returns `!markedForEviction`),
and a check in `NaiveVersionManager.swapTo()` that rejects swaps to
evicted versions. This closes the stale-map crash path from
Finding 01 — but only for the specific 500-error symptom, not for
the underlying lifecycle defect.

### 2.3 Slow inference endpoint

`POST /infer/slow?sleepMs=N` — sleeps for N ms inside the
acquire/release window, before running ONNX. This is the pinning
mechanism: the version stays pinned for the full sleep duration.

### 2.4 Per-instance gauge fix

Added a UUID `instanceId` tag to both per-version gauges. Without
this, Micrometer silently reuses the gauge for repeated loads of the
same version ID, reporting through the *first* instance's state
forever (Finding 02). With the fix, each `ModelVersion` instance
registers its own gauge and can be observed individually.

### 2.5 Harness scripts

| File | Purpose |
|------|---------|
| `harness/load-generator.ps1` | N parallel workers, configurable duration and slow-request percentage |
| `harness/swap-loop.ps1`         | Alternates v1↔v2 on a timer, reloads before swap |
| `harness/snapshot.ps1`          | Captures counters, per-version gauges, WS/PM, NMT |
| `harness/pinning-proof.ps1`     | Isolated single-request pinning demonstration |

---

## 3. Experiments

### 3.1 Experiment A — Fast traffic, normal cadence

| Setting | Value |
|---------|-------|
| Workers | 8 |
| Slow % | 0 |
| Duration | 200 s |
| Swap interval | 2000 ms |
| Requests | 662,024 |
| Throughput | 3,041 req/s |
| Swaps | 98 |
| Errors | **0** |

Memory drift: WS 219 → 231 MB, PM 268 → 276 MB, NMT 247 → 251 MB.
Most growth front-loaded during JIT warmup.

Eviction lag: exactly 1 throughout. Only the current version alive
at any moment.

**Result:** negative. Naive design handles fast traffic + concurrent
swaps with zero errors and no meaningful memory growth.

### 3.2 Experiment B — Slow requests pin old versions

| Setting | Value |
|---------|-------|
| Workers | 8 |
| Slow % | 10 (5000 ms sleeps) |
| Duration | 182 s |
| Swap interval | 2000 ms |
| Requests | 2,969 |
| Throughput | 16 req/s (correctly reduced by sleeping workers) |
| Swaps | 90 |
| Errors | **0** |

Memory drift: WS 195 → 205 MB, PM 247 → 262 MB, NMT 217 → 223 MB.

Eviction lag: baseline 1, grew to **5** at t90, returned to 4 at
t180 as loads drained. `active.requests{v1}=6, {v2}=2` at peak.

**Result:** pinning confirmed at scale. Multiple old versions
simultaneously alive-but-marked-dead, held by in-flight slow
requests. Memory cost invisible at MNIST scale (26 KB per model).

### 3.2.1 Experiment B — Isolated pinning proof

Single 10-second slow request against v1, swap to v2 mid-flight.

| Point | active v1 | marked v1 | evict.count |
|-------|-----------|-----------|-------------|
| Before slow req | 0 | 1 | 2 |
| Slow req in flight | 1 | 1 | 2 |
| Swap to v2 | 1 | **2** | **2** ← marked, not evicted |
| Slow req finishes | 0 | 2 | **3** ← evict fires |

**Result:** definitive. The swap marked v1 for eviction but the
actual `session.close()` was deferred until the slow request
released its reference, exactly 10 seconds later.

### 3.3 Experiment C — Aggressive swap cadence

| Setting | Value |
|---------|-------|
| Workers | 8 |
| Slow % | 0 |
| Duration | 120 s |
| Swap interval | **300 ms** (6× faster than A/B) |
| Requests | 550,022 |
| Throughput | 4,502 req/s |
| Swaps | 353 |
| Errors | **0** |

Memory growth: WS 193 → 305 MB (**+112 MB**), then held at 301 MB
during 60 s of idle.

**Post-hoc forced GC test (`jcmd GC.run`):** WS dropped to
**191 MB** — full recovery of ~110 MB.

**Result:** originally interpreted as a native leak. Corrected by
the GC test to be **JVM retention of orphaned ModelVersion
objects**. The retention path is the Micrometer gauge closures
(Finding 02) plus un-cleared map entries (Finding 01). Under
normal operation, no code path triggers the GC that would reclaim
them, so the growth appears monotonic in swap count.

---

## 4. Findings

### Finding 01 — Stale version swap causes 500

Once a version is evicted, its entry stays in `versions`. `swapTo`
originally checked only `containsKey`, not liveness. Swapping back
to an evicted version silently succeeded, then `/infer` returned
HTTP 500.

**Status:** guard added (`isAlive()` check). Underlying map-leak
still present.

### Finding 02 — Micrometer gauge binding reuse

`Gauge.builder(...).tag("version", id).register(registry)` returns
the *existing* gauge for the same (name, tags). Reloading a version
discards the new gauge and leaves the old one reporting forever.
After 68 swaps, both v1 and v2 gauges reported `1.0` — frozen to
ghost objects.

**Status:** fixed via per-instance UUID tag. Side effect: gauges
accumulate per instance, becoming a secondary retention path
(contributing to Finding 06).

### Finding 03 — Experiment A results

Fast traffic + 98 swaps = 0 errors, ~11 MB growth (warmup).
Negative result. Naive design is *correct* under this workload.

### Finding 04 — Isolated pinning proof

A single slow request defers eviction by exactly its own duration.
Confirmed via `evict.count` staying flat during the pin, then
advancing after.

**Classification:** unbounded pinning. Eviction latency is bounded
only by the slowest in-flight request.

### Finding 05 — Experiment B (scaled)

Under 10% slow request load, eviction lag grew from 1 to 5.
Memory cost invisible at MNIST scale; expected to matter for real
models.

### Finding 06 — Experiment C (aggressive cadence)

353 swaps in 120 s produced +112 MB of WS growth that did **not**
recover during 60 s of idle. Initial interpretation: native leak.
Post-GC test corrected this: `jcmd GC.run` recovered 110 MB.

**Classification:** unbounded JVM retention. GC-recoverable, but
the code provides no mechanism to *trigger* that recovery, and
monotonic growth is observable during operation.

---

## 5. Defect summary

| # | Defect | Trigger | Symptom | Recoverable? |
|---|--------|---------|---------|--------------|
| 1 | Stale map entries | Swap to evicted version | 500 on `/infer` | Fixed by guard |
| 2 | Unbounded pinning | Slow request + swap mid-flight | Eviction delayed indefinitely | Only when request drains |
| 3 | JVM retention of orphans | Rapid swap cadence | Monotonic RSS growth | Only via full GC, no code path triggers it |

Defect 3 is the most research-relevant. It is not a bug in the
strict sense — the code never promised to free old versions — but
it makes the naive design unsafe for long-running production use
with non-trivial model sizes.

---

## 6. Quantitative results table

For direct inclusion in the paper:

| Metric | Exp A | Exp B | Exp C |
|--------|-------|-------|-------|
| Workers | 8 | 8 | 8 |
| Slow % | 0 | 10 | 0 |
| Swap interval | 2000 ms | 2000 ms | 300 ms |
| Duration | 200 s | 182 s | 120 s |
| Requests | 662,024 | 2,969 | 550,022 |
| Throughput | 3,041 req/s | 16 req/s | 4,502 req/s |
| Swaps | 98 | 90 | 353 |
| Errors | 0 | 0 | 0 |
| Max eviction lag | 1 | **5** | 4 |
| WS delta (during run) | +11 MB | +10 MB | **+112 MB** |
| WS delta after full GC | n/a | n/a | **−110 MB** |
| Per-swap retention | 0.11 MB | 0.11 MB | **0.32 MB** |
| Pinning demonstrated | no | yes | no |
| Native leak | no | no | no |

---

## 7. Methodological notes

### 7.1 The negative result matters

Experiment A's zero-error, low-growth result is a **boundary
condition**. It tells us the naive design is fine under pure fast
concurrent load. The failure modes are specifically tied to:

- slow requests (Exp B),
- aggressive swap cadence (Exp C),

...not to concurrency alone. This is a precise, useful claim for
the paper: concurrency by itself is not the problem; the problem
is the interaction between request latency and version churn.

### 7.2 Self-correction on Finding 06

The initial interpretation of Experiment C was a native memory
leak — the growth was monotonic during operation and did not
recover during idle. Forcing a full GC corrected this: the
"leaked" memory was JVM retention of orphaned objects, not
native escape.

This correction is worth calling out explicitly in the paper's
methodology section. It demonstrates that:

- "RSS grows during operation" is **not** sufficient evidence of
  a leak.
- The correct test for native leaks is to force a GC and re-measure.
- Distinguishing JVM retention from native escape is essential for
  correctly categorizing a defect and targeting the right fix.

This is the kind of rigor that separates "we built a demo" from
"we ran an experiment."

---

## 8. Stage 3 — Required fixes

Based on Stage 2's evidence, the protocol redesign must address:

1. **Map cleanup on evict** — `versions.remove(previousId)` after
   a version's refcount hits 0 and it is evicted. Removes the
   primary retention path from Finding 06.
2. **Gauge deregistration on evict** — track registered `Gauge`
   objects per instance and call `registry.remove(...)` on evict.
   Removes the secondary retention path.
3. **Bounded eviction policy** — either cap concurrent pinned
   versions, force-close sessions after a configurable timeout,
   or apply backpressure to the swap rate when eviction lags.
4. **Consider session pooling** — replace per-load
   `createSession` with a small pool, to avoid repeated
   create/close churn on the ONNX allocator.

Stage 4 will re-run A/B/C against the fixed code and compare
memory curves, eviction lag, and error counts.

---

## 9. Reproducibility

All raw snapshots are preserved in `harness/results/`. Each file
is named `<label>-<timestamp>.txt` and contains counters,
per-version gauges, process working set, private memory, and
NMT total committed.

To reproduce:

1. Build and run: `mvn spring-boot:run`
2. Capture baseline: `harness/snapshot.ps1 -Label baseline -ProcessId <PID>`
3. Run load + swaps concurrently per experiment setup
4. Capture mid/end snapshots at the specified times
5. For leak testing: `jcmd <PID> GC.run` then re-snapshot

---

## 10. Files produced in Stage 2

    findings/
      finding-01-stale-version-swap.md
      finding-02-gauge-registration-leak.md
      finding-03-expA-results.md
      finding-04-pinning-proof.md
      finding-05-expB-results.md
      finding-06-expC-results.md
      stage-2-summary.md          (this file)

    harness/
      load-generator.ps1
      swap-loop.ps1
      snapshot.ps1
      pinning-proof.ps1
      results/*.txt

    Code changes:
      pom.xml                     (NMT flag)
      ModelVersion.java           (isAlive, instanceId, per-instance tags)
      NaiveVersionManager.java    (swap guard)
      InferenceService.java       (slow-mode overload)
      InferenceController.java    (/infer/slow endpoint)