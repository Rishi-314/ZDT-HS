package com.EDI.ZDT_HS.inference;

import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/infer")
public class InferenceController {

    private final InferenceService inferenceService;

    public InferenceController(InferenceService inferenceService) {
        this.inferenceService = inferenceService;
    }

    @PostMapping
    public float[] infer(@RequestBody InferRequest request) throws Exception {
        return inferenceService.infer(request.data(), request.shape());
    }

    public record InferRequest(float[] data, long[] shape) {}
}