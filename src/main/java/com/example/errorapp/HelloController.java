package com.example.errorapp;

import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    private final double errorRate;
    private final String version;

    public HelloController(@Value("${ERROR_RATE:0}") double errorRate,
                           @Value("${APP_VERSION:v1}") String version) {
        this.errorRate = errorRate;
        this.version = version;
    }

    @GetMapping("/api/hello")
    public ResponseEntity<Map<String, Object>> hello() {
        if (ThreadLocalRandom.current().nextDouble() < errorRate) {
            return ResponseEntity.status(500).body(Map.of("version", version, "result", "error"));
        }
        return ResponseEntity.ok(Map.of("version", version, "result", "ok"));
    }
}
