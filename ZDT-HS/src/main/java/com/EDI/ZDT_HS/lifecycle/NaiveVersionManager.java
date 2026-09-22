package com.EDI.ZDT_HS.lifecycle;

import java.time.Instant;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import org.springframework.stereotype.Component;

import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;

@Component
public class NaiveVersionManager {

    /** Timeout after which a pinned version is force-evicted. */
    public static final long EVICTION_TIMEOUT_MS = 2000L;

    private final OrtEnvironment env = OrtEnvironment.getEnvironment();
    private final ConcurrentHashMap<String, ModelVersion> versions = new ConcurrentHashMap<>();
    private final AtomicReference<String> currentVersionId = new AtomicReference<>();

    private final MeterRegistry registry;
    private final Counter loadCounter;
    private final Counter swapCounter;

    private final ScheduledExecutorService watchdog =
            Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "eviction-watchdog");
                t.setDaemon(true);
                return t;
            });

    public NaiveVersionManager(MeterRegistry registry) {
        this.registry = registry;
        this.loadCounter = Counter.builder("model.load.count")
                .description("Number of model versions loaded")
                .register(registry);
        this.swapCounter = Counter.builder("model.swap.count")
                .description("Number of hot swaps performed")
                .register(registry);
    }

    @PostConstruct
    void startWatchdog() {
        watchdog.scheduleAtFixedRate(
                this::sweepStaleVersions, 1, 1, TimeUnit.SECONDS);
    }

    @PreDestroy
    void stopWatchdog() {
        watchdog.shutdownNow();
    }

    private void sweepStaleVersions() {
        Instant cutoff = Instant.now().minusMillis(EVICTION_TIMEOUT_MS);
        for (ModelVersion v : versions.values()) {
            Instant markedAt = v.getMarkedAt();
            if (v.isMarkedForEviction()
                    && v.getActiveRequestCount() > 0
                    && markedAt != null
                    && markedAt.isBefore(cutoff)) {
                try {
                    v.forceEvict();
                } catch (Exception e) {
                    System.err.println(">>> Watchdog error on " + v.getVersionId()
                            + ": " + e.getMessage());
                }
            }
        }
    }

    public void loadVersion(String versionId, String modelPath) throws Exception {
        OrtSession session = env.createSession(modelPath, new OrtSession.SessionOptions());

        ModelVersion version = new ModelVersion(versionId, session, env, registry,
                v -> versions.remove(versionId, v));

        versions.put(versionId, version);
        loadCounter.increment();
        System.out.println(">>> Loaded model version: " + versionId + " from " + modelPath);
    }

    public void swapTo(String versionId) {
        ModelVersion target = versions.get(versionId);
        if (target == null) {
            throw new IllegalArgumentException("Version not loaded: " + versionId);
        }
        if (!target.isAlive()) {
            throw new IllegalStateException(
                    "Version " + versionId + " has been evicted and cannot be swapped to");
        }
        String previousId = currentVersionId.getAndSet(versionId);
        swapCounter.increment();
        System.out.println(">>> Swapped current version: " + previousId + " -> " + versionId);
        if (previousId != null && !previousId.equals(versionId)) {
            ModelVersion previous = versions.get(previousId);
            if (previous != null) {
                previous.markForEviction();
            }
        }
    }

    public ModelVersion getCurrentVersion() {
        String id = currentVersionId.get();
        if (id == null) {
            throw new IllegalStateException("No active model version set");
        }
        ModelVersion version = versions.get(id);
        if (version == null) {
            throw new IllegalStateException("Current version not found: " + id);
        }
        version.acquire();
        return version;
    }

    public String getCurrentVersionId() {
        return currentVersionId.get();
    }

    public Set<String> getLoadedVersionIds() {
        return versions.keySet();
    }

    public java.util.Collection<ModelVersion> getLoadedVersions() {
        return new java.util.ArrayList<>(versions.values());
    }
}