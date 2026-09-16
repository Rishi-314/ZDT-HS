# Finding 02 — Micrometer Gauge Registration Leak (Stale Binding)

**Date:** 2026-09-12
**Stage:** 2 (Experiment A)
**Status:** Confirmed

## Summary

Per-version Micrometer gauges are registered once per (name, tag set)
in the MeterRegistry. When a ModelVersion with the same versionId is
re-loaded after eviction, `Gauge.builder(...).tag("version", id).register(...)`
returns the *existing* gauge — the new binding is discarded. The gauge
therefore remains bound to the first ModelVersion object ever created
with that ID, and reports that object's state forever.

## Observed

After 68+ swaps, both v1 and v2 gauges report:

  model.version.marked.for.eviction{version=v1} = 1.0
  model.version.marked.for.eviction{version=v2} = 1.0

...even though exactly one version is currently active (marked=0).
The "1.0" values are stale bindings to the very first v1/v2 ModelVersion
objects, which were evicted many cycles ago.

## Consequence

Post-first-eviction, per-version gauges are unusable for observing:
- whether the current version is pinned by slow requests
- how many requests are in flight for the currently-active version

This invalidates any Stage 2 measurement that relies on these gauges
unless the binding leak is fixed.

## Root cause

Micrometer's `register()` contract: identical (name, tags) yields the
same Meter. Our code does not deregister the old gauge before
registering a new one, and Micrometer does not provide first-class
"remove by name+tags" until much later versions.

## Stage 3 fix direction

Options (not yet implemented):
- Tag gauges with a per-instance unique ID (e.g. `instance`, UUID)
  in addition to `version`.
- Deregister via `registry.remove(gauge)` on evict.
- Replace per-version gauges with a single MultiGauge rebuilt on demand.