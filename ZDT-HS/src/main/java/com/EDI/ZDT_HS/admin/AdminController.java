package com.EDI.ZDT_HS.admin;

import com.EDI.ZDT_HS.lifecycle.NaiveVersionManager;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/admin/models")
public class AdminController {

    private final NaiveVersionManager versionManager;

    public AdminController(NaiveVersionManager versionManager) {
        this.versionManager = versionManager;
    }

    @PostMapping("/load")
    public String load(@RequestParam String versionId, @RequestParam String path) throws Exception {
        versionManager.loadVersion(versionId, path);
        return "Loaded version: " + versionId;
    }

    @PostMapping("/swap")
    public String swap(@RequestParam String versionId) {
        versionManager.swapTo(versionId);
        return "Swapped to version: " + versionId;
    }

    @GetMapping("/current")
    public String current() {
        return versionManager.getCurrentVersionId();
    }
}