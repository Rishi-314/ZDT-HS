package com.EDI.ZDT_HS.inference;

import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

@RestControllerAdvice
public class ModelRetiredExceptionHandler {

    @ExceptionHandler(ModelRetiredException.class)
    public ResponseEntity<Map<String, Object>> handle(ModelRetiredException e) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("error", "model_version_retired");
        body.put("retired_version", e.getRetiredVersion());
        body.put("current_version", e.getCurrentVersion());
        body.put("message",
                "Your request was executing on model " + e.getRetiredVersion()
                + ", which was retired. Retry immediately to reach "
                + e.getCurrentVersion() + ".");
        body.put("retry_safe", true);

        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .header("Retry-After", "0")
                .body(body);
    }
}