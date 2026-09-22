package com.EDI.ZDT_HS.lifecycle;

import java.time.Instant;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;

import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import io.micrometer.core.instrument.Gauge;
import io.micrometer.core.instrument.MeterRegistry;

public class ModelVersion {

    private final String versionId;
    private final String instanceId;
    private final OrtSession session;
    private final OrtEnvironment environment;
    private final AtomicInteger activeRequests = new AtomicInteger(0);
    private final AtomicBoolean evicted = new AtomicBoolean(false);
    private volatile boolean markedForEviction = false;
    private volatile Instant markedAt = null;
    private volatile boolean forcedEviction = false;

    private final MeterRegistry registry;
    private final Consumer<ModelVersion> onEvicted;
    private final Gauge activeRequestsGauge;
    private final Gauge markedGauge;

    public ModelVersion(String versionId, OrtSession session, OrtEnvironment environment,
                        MeterRegistry registry, Consumer<ModelVersion> onEvicted) {
        this.versionId = versionId;
        this.instanceId = UUID.randomUUID().toString();
        this.session = session;
        this.environment = environment;
        this.registry = registry;
        this.onEvicted = onEvicted;

        this.activeRequestsGauge = Gauge.builder("model.version.active.requests",
                        activeRequests, AtomicInteger::get)
                .description("In-flight inference requests per model version")
                .tag("version", versionId)
                .tag("instance", instanceId)
                .register(registry);

        this.markedGauge = Gauge.builder("model.version.marked.for.eviction",
                        () -> markedForEviction ? 1 : 0)
                .description("1 if the version is marked for eviction, else 0")
                .tag("version", versionId)
                .tag("instance", instanceId)
                .register(registry);
    }

    public void acquire() {
        activeRequests.incrementAndGet();
    }

    public void release() {
        int remaining = activeRequests.decrementAndGet();
        if (remaining == 0 && markedForEviction) {
            evict(false);
        }
    }

    public void markForEviction() {
        this.markedAt = Instant.now();
        this.markedForEviction = true;
        if (activeRequests.get() == 0) {
            evict(false);
        }
    }

    /**
     * Called by the eviction watchdog when a version has been marked
     * for eviction and refcount stayed > 0 past the timeout.
     * Forces session close even though requests are still in flight.
     */
    public void forceEvict() {
        if (!markedForEviction) {
            throw new IllegalStateException(
                    "Cannot force-evict unmarked version " + versionId);
        }
        evict(true);
    }

    private void evict(boolean forced) {
        // idempotent — only one caller wins the race
        if (!evicted.compareAndSet(false, true)) {
            return;
        }
        this.forcedEviction = forced;
        try {
            session.close();

            if (forced) {
                registry.counter("model.forced.evict.count").increment();
            } else {
                registry.counter("model.evict.count").increment();
            }

            registry.remove(activeRequestsGauge);
            registry.remove(markedGauge);

            onEvicted.accept(this);

            System.out.println(">>> " + (forced ? "FORCED-evicted" : "Evicted")
                    + " model version: " + versionId
                    + " [instance=" + instanceId.substring(0, 8) + "]");
        } catch (Exception e) {
            System.err.println(">>> Eviction failed for " + versionId + ": " + e.getMessage());
        }
    }

    public OrtSession getSession()         { return session; }
    public OrtEnvironment getEnvironment() { return environment; }
    public String getVersionId()           { return versionId; }
    public String getInstanceId()          { return instanceId; }
    public int getActiveRequestCount()     { return activeRequests.get(); }
    public boolean isMarkedForEviction()   { return markedForEviction; }
    public boolean isAlive()               { return !markedForEviction; }
    public Instant getMarkedAt()           { return markedAt; }
    public boolean isForcedEviction()      { return forcedEviction; }
}