package com.EDI.ZDT_HS.lifecycle;

import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import org.springframework.stereotype.Component;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicReference;

@Component
public class NaiveVersionManager {

    private final OrtEnvironment env = OrtEnvironment.getEnvironment();
    private final ConcurrentHashMap<String, ModelVersion> versions = new ConcurrentHashMap<>();
    private final AtomicReference<String> currentVersionId = new AtomicReference<>();

    public void loadVersion(String versionId, String modelPath) throws Exception {
        OrtSession session = env.createSession(modelPath, new OrtSession.SessionOptions());
        ModelVersion version = new ModelVersion(versionId, session, env);
        versions.put(versionId, version);
        System.out.println(">>> Loaded model version: " + versionId + " from " + modelPath);
    }

    public void swapTo(String versionId) {
        if (!versions.containsKey(versionId)) {
            throw new IllegalArgumentException("Version not loaded: " + versionId);
        }
        String previousId = currentVersionId.getAndSet(versionId);
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
}