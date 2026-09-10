package com.EDI.ZDT_HS.lifecycle;

import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import java.util.concurrent.atomic.AtomicInteger;

public class ModelVersion {

    private final String versionId;
    private final OrtSession session;
    private final OrtEnvironment environment;
    private final AtomicInteger activeRequests = new AtomicInteger(0);
    private volatile boolean markedForEviction = false;

    public ModelVersion(String versionId, OrtSession session, OrtEnvironment environment) {
        this.versionId = versionId;
        this.session = session;
        this.environment = environment;
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
            System.out.println(">>> Evicted model version: " + versionId);
        } catch (Exception e) {
            System.err.println(">>> Eviction failed for " + versionId + ": " + e.getMessage());
        }
    }

    public OrtSession getSession()         { return session; }
    public OrtEnvironment getEnvironment() { return environment; }
    public String getVersionId()           { return versionId; }
    public int getActiveRequestCount()     { return activeRequests.get(); }
    public boolean isMarkedForEviction()   { return markedForEviction; }
}