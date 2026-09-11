package com.EDI.ZDT_HS.inference;

import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

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

    @PostMapping("/slow")
    public float[] inferSlow(@RequestBody InferRequest request,
                             @RequestParam(defaultValue = "5000") long sleepMs) throws Exception {
        return inferenceService.infer(request.data(), request.shape(), sleepMs);
    }

    public record InferRequest(float[] data, long[] shape) {}
}