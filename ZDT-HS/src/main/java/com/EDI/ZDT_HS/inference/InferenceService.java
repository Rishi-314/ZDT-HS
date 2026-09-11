package com.EDI.ZDT_HS.inference;

import java.nio.FloatBuffer;
import java.util.Collections;
import java.util.Map;

import org.springframework.stereotype.Service;

import com.EDI.ZDT_HS.lifecycle.ModelVersion;
import com.EDI.ZDT_HS.lifecycle.NaiveVersionManager;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;

@Service
public class InferenceService {

    private final NaiveVersionManager versionManager;

    public InferenceService(NaiveVersionManager versionManager) {
        this.versionManager = versionManager;
    }

    public float[] infer(float[] inputData, long[] inputShape) throws Exception {
        return infer(inputData, inputShape, 0L);
    }

    public float[] infer(float[] inputData, long[] inputShape, long sleepMs) throws Exception {
        ModelVersion version = versionManager.getCurrentVersion();
        try {
            if (sleepMs > 0) {
                Thread.sleep(sleepMs);
            }

            OrtEnvironment env = version.getEnvironment();
            String inputName = version.getSession().getInputNames().iterator().next();

            try (OnnxTensor inputTensor = OnnxTensor.createTensor(
                    env, FloatBuffer.wrap(inputData), inputShape)) {

                Map<String, OnnxTensor> inputs = Collections.singletonMap(inputName, inputTensor);

                try (OrtSession.Result result = version.getSession().run(inputs)) {
                    Object value = result.get(0).getValue();
                    if (value instanceof float[][] f2) return f2[0];
                    if (value instanceof float[]  f1) return f1;
                    throw new IllegalStateException(
                            "Unexpected output type: " + value.getClass());
                }
            }
        } finally {
            version.release();
        }
    }
}