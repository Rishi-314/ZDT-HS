package com.EDI.ZDT_HS.lifecycle;

import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

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
    private volatile boolean markedForEviction = false;
    private final MeterRegistry registry;

    public ModelVersion(String versionId, OrtSession session, OrtEnvironment environment,
                        MeterRegistry registry) {
        this.versionId = versionId;
        this.instanceId = UUID.randomUUID().toString();
        this.session = session;
        this.environment = environment;
        this.registry = registry;

        Gauge.builder("model.version.active.requests", activeRequests, AtomicInteger::get)
                .description("In-flight inference requests per model version")
                .tag("version", versionId)
                .tag("instance", instanceId)
                .register(registry);

        Gauge.builder("model.version.marked.for.eviction", () -> markedForEviction ? 1 : 0)
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
            evict();
        }
    }

    public void markForEviction() {
        this.markedForEviction = true;
        if (activeRequests.get() == 0) {
            evict();
        }
    }

    private void evict() {
        try {
            session.close();
            registry.counter("model.evict.count").increment();
            System.out.println(">>> Evicted model version: " + versionId + " [instance=" + instanceId.substring(0, 8) + "]");
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
}