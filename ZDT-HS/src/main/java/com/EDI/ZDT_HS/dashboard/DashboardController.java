package com.EDI.ZDT_HS.dashboard;

import com.EDI.ZDT_HS.lifecycle.ModelVersion;
import com.EDI.ZDT_HS.lifecycle.NaiveVersionManager;
import io.micrometer.core.instrument.Counter;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

@RestController
@RequestMapping("/api/dashboard")
public class DashboardController {

    private final NaiveVersionManager versionManager;

    public DashboardController(NaiveVersionManager versionManager) {
        this.versionManager = versionManager;
    }

    @GetMapping("/state")
    public Map<String, Object> state() {
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("currentVersion", versionManager.getCurrentVersionId());

        long pid = ProcessHandle.current().pid();
        out.put("pid", pid);

        // Per-version table
        List<Map<String, Object>> versions = new ArrayList<>();
        for (ModelVersion v : versionManager.getLoadedVersions()) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("id", v.getVersionId());
            row.put("instance", v.getInstanceId().substring(0, 8));
            row.put("activeRequests", v.getActiveRequestCount());
            row.put("markedForEviction", v.isMarkedForEviction());
            row.put("alive", v.isAlive());
            versions.add(row);
        }
        out.put("versions", versions);

        // JVM heap / non-heap
        MemoryMXBean mem = ManagementFactory.getMemoryMXBean();
        out.put("heapUsed", mem.getHeapMemoryUsage().getUsed());
        out.put("heapMax", mem.getHeapMemoryUsage().getMax());
        out.put("nonHeapUsed", mem.getNonHeapMemoryUsage().getUsed());

        // Counters via actuator (same data as /actuator/metrics/*)
        out.put("counters", Map.of(
                "load",  counterValue("model.load.count"),
                "swap",  counterValue("model.swap.count"),
                "evict", counterValue("model.evict.count")
        ));

        // Process working set + NMT — cached with 2s TTL
        out.put("workingSetBytes", cachedWorkingSet(pid));
        out.put("nmtCommittedBytes", cachedNmt(pid));

        return out;
    }

    private double counterValue(String name) {
        // Read via MeterRegistry.find so we don't need an injected registry reference.
        try {
            var meters = io.micrometer.core.instrument.Metrics.globalRegistry.find(name).counters();
            for (Counter c : meters) return c.count();
        } catch (Exception ignored) {}
        return 0.0;
    }

    // -------- working set via PowerShell, cached --------

    private long lastWorkingSet = -1;
    private long lastWorkingSetAt = 0;

    private long cachedWorkingSet(long pid) {
        long now = System.currentTimeMillis();
        if (now - lastWorkingSetAt < 2000 && lastWorkingSet >= 0) return lastWorkingSet;
        lastWorkingSet = queryWorkingSet(pid);
        lastWorkingSetAt = now;
        return lastWorkingSet;
    }

    private long queryWorkingSet(long pid) {
        try {
            Process p = new ProcessBuilder(
                    "powershell", "-NoProfile", "-Command",
                    "(Get-Process -Id " + pid + " -ErrorAction SilentlyContinue).WorkingSet64")
                    .redirectErrorStream(true).start();
            if (!p.waitFor(3, TimeUnit.SECONDS)) { p.destroyForcibly(); return -1; }
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                String line = r.readLine();
                if (line == null || line.isBlank()) return -1;
                return Long.parseLong(line.trim());
            }
        } catch (Exception e) {
            return -1;
        }
    }

    // -------- NMT committed, cached --------

    private static final Pattern NMT_TOTAL =
            Pattern.compile("Total:.*committed=(\\d+)KB");

    private long lastNmt = -1;
    private long lastNmtAt = 0;

    private long cachedNmt(long pid) {
        long now = System.currentTimeMillis();
        if (now - lastNmtAt < 5000 && lastNmt >= 0) return lastNmt;
        lastNmt = queryNmt(pid);
        lastNmtAt = now;
        return lastNmt;
    }

    private long queryNmt(long pid) {
        try {
            Process p = new ProcessBuilder(
                    "jcmd", String.valueOf(pid), "VM.native_memory", "summary")
                    .redirectErrorStream(true).start();
            if (!p.waitFor(3, TimeUnit.SECONDS)) { p.destroyForcibly(); return -1; }
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = r.readLine()) != null) {
                    Matcher m = NMT_TOTAL.matcher(line);
                    if (m.find()) {
                        return Long.parseLong(m.group(1)) * 1024L;   // KB -> bytes
                    }
                }
            }
        } catch (Exception e) {
            return -1;
        }
        return -1;
    }
}