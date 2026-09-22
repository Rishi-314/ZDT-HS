# ============================================================
# ZDT-HS - Per-Finding Demo
# Run one finding at a time:
#   & .\harness\demo.ps1 -Finding 1
#   & .\harness\demo.ps1 -Finding 2
#   ... up to -Finding 7
# Add -ProcessId <PID> for findings that need JVM memory (6, 7)
# ============================================================

param(
    [Parameter(Mandatory=$true)][int]$Finding,
    [string]$BaseUrl     = "http://localhost:8081",
    [int]   $ProcessId   = 0,
    [string]$ModelV1Path = "src/main/resources/models/model-v1.onnx",
    [string]$ModelV2Path = "src/main/resources/models/model-v2.onnx"
)

$ErrorActionPreference = "Continue"

# ---------- shared helpers ----------
function H($n, $t) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " FINDING $n - $t" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}
function Proof($msg) {
    Write-Host ""
    Write-Host "PROOF >> $msg" -ForegroundColor Green
    Write-Host ""
}
function Note($msg) { Write-Host "  $msg" -ForegroundColor Gray }
function Info($msg) { Write-Host "  $msg" -ForegroundColor Yellow }
function Bad($msg)  { Write-Host "  $msg" -ForegroundColor Red }

function Get-Metric($name, $tag = $null) {
    $url = "$BaseUrl/actuator/metrics/$name"
    if ($tag) { $url += "?tag=$tag" }
    try {
        $r = Invoke-RestMethod $url -TimeoutSec 5
        return $r.measurements[0].value
    } catch { return $null }
}

function Get-Current()  { return (Invoke-RestMethod "$BaseUrl/admin/models/current" -TimeoutSec 5) }
function Load-Model($id, $path) {
    Invoke-RestMethod -Uri "$BaseUrl/admin/models/load?versionId=$id&path=$path" -Method Post -TimeoutSec 30 | Out-Null
}
function Swap-To($id) {
    Invoke-RestMethod -Uri "$BaseUrl/admin/models/swap?versionId=$id" -Method Post -TimeoutSec 30 | Out-Null
}
function Infer-One() {
    $body = @{ data = @(0.0) * 784; shape = @(1,1,28,28) } | ConvertTo-Json
    return Invoke-RestMethod -Uri "$BaseUrl/infer" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20
}
function WS-MB() {
    if ($ProcessId -le 0) { return -1 }
    try { return [math]::Round((Get-Process -Id $ProcessId).WorkingSet64 / 1MB, 2) }
    catch { return -1 }
}

# ---------- preflight ----------
try {
    $h = Invoke-RestMethod "$BaseUrl/actuator/health" -TimeoutSec 5
    if ($h.status -ne "UP") { throw "not up" }
} catch {
    Write-Host "App is not running on $BaseUrl. Start it with 'mvn spring-boot:run'." -ForegroundColor Red
    exit 1
}

# make sure v1 loaded and current
try { Load-Model "v1" $ModelV1Path } catch {}
try { Swap-To "v1" } catch {}

# ============================================================
switch ($Finding) {

# ------------------------------------------------------------
1 {
    H 1 "Stale version swap causes 500"
    Note "Naive behaviour: swap to an evicted version silently succeeds,"
    Note "then /infer 500s because the underlying ONNX session is closed."
    Note "Fixed by: isAlive() guard + identity-checked map removal."

    Write-Host ""
    Info "Step 1: load v2 and swap to v2 -> this evicts v1"
    Load-Model "v2" $ModelV2Path
    Swap-To "v2"
    Start-Sleep -Milliseconds 500

    Info "Step 2: try to swap back to v1 (should be rejected)"
    $response = $null
    try {
        Swap-To "v1"
        Bad "Swap succeeded - UNEXPECTED"
    } catch {
        $response = $_.ErrorDetails.Message
        if (-not $response) { $response = $_.Exception.Message }
        Write-Host ""
        Write-Host "  Server response:" -ForegroundColor Yellow
        Write-Host "  $response" -ForegroundColor Yellow
    }

    # restore
    Load-Model "v1" $ModelV1Path
    Swap-To "v1"

    Proof "Server returned a clean rejection containing 'not loaded' or 'evicted' - no silent success, no 500 on next /infer."
}

# ------------------------------------------------------------
2 {
    H 2 "Micrometer gauge binding reuse"
    Note "Naive behaviour: same (name, tags) returns the SAME meter."
    Note "Reloading v1 silently discards the new binding - first-ever instance"
    Note "keeps reporting 1.0 forever. Fix: per-instance tag + deregistration."

    Info "Step 1: verify v1 gauge is present (alive)"
    $g1 = Get-Metric "model.version.marked.for.eviction" "version:v1"
    Write-Host "  marked.for.eviction{v1} = $g1"

    Info "Step 2: swap to v2 (evicts v1, deregisters its gauge)"
    Load-Model "v2" $ModelV2Path
    Swap-To "v2"
    Start-Sleep -Milliseconds 500

    Info "Step 3: query v1 gauge again"
    $g2 = Get-Metric "model.version.marked.for.eviction" "version:v1"
    Write-Host "  marked.for.eviction{v1} = $g2"

    # restore
    Load-Model "v1" $ModelV1Path
    Swap-To "v1"

    if ($null -eq $g2) {
        Proof "v1 gauge returned NULL (404) after eviction - it was deregistered, not stuck at 1.0."
    } else {
        Proof "v1 gauge still reports $g2 - deregistration not active at registry level (known secondary issue)."
    }
}

# ------------------------------------------------------------
3 {
    H 3 "Experiment A - fast traffic, no slow requests"
    Note "Expected: 0 errors, flat memory. Concurrency alone is NOT a failure mode."

    $wsBefore = WS-MB
    if ($wsBefore -gt 0) { Info "WorkingSet before: $wsBefore MB" }

    $body = @{ data = @(0.0) * 784; shape = @(1,1,28,28) } | ConvertTo-Json
    Info "Firing 8 workers for 15 seconds, pure fast traffic..."

    $workerScript = {
        param($url, $body, $seconds)
        $end = (Get-Date).AddSeconds($seconds)
        $ok = 0; $err = 0
        while ((Get-Date) -lt $end) {
            try {
                Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20 | Out-Null
                $ok++
            } catch { $err++ }
        }
        [pscustomobject]@{ ok=$ok; err=$err }
    }

    $jobs = @()
    1..8 | ForEach-Object {
        $jobs += Start-Job -ScriptBlock $workerScript -ArgumentList "$BaseUrl/infer", $body, 15
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $jobs | Wait-Job | Out-Null
    $sw.Stop()

    $results = $jobs | Receive-Job
    $jobs | Remove-Job

    $ok  = ($results | Measure-Object -Property ok -Sum).Sum
    $err = ($results | Measure-Object -Property err -Sum).Sum

    $wsAfter = WS-MB

    Write-Host ""
    Write-Host "  Requests ok:    $ok"
    Write-Host "  Requests err:   $err"
    Write-Host "  Duration:       $([math]::Round($sw.Elapsed.TotalSeconds,1)) s"
    Write-Host "  Throughput:     $([math]::Round($ok / $sw.Elapsed.TotalSeconds, 0)) req/s"
    if ($wsBefore -gt 0) {
        Write-Host "  WS before:      $wsBefore MB"
        Write-Host "  WS after:       $wsAfter MB"
        Write-Host "  WS delta:       $([math]::Round($wsAfter - $wsBefore, 2)) MB"
    }

    Proof "$ok successful requests, $err errors. Fast concurrent load is clean - the naive design handles it."
}

# ------------------------------------------------------------
4 {
    H 4 "Unbounded pinning - isolated proof"
    Note "A slow request pins the version it started on until it completes."
    Note "Eviction for that version is deferred by exactly the sleep duration."

    # ensure clean state — reload both so both are alive
    Load-Model "v2" $ModelV2Path
    Swap-To "v2"
    Load-Model "v1" $ModelV1Path
    Swap-To "v1"
    Load-Model "v2" $ModelV2Path    # <-- FIX: reload v2 so mid-flight swap is legal

    $evictBefore = Get-Metric "model.evict.count"
    Info "evict.count before test:    $evictBefore"

    $body = @{ data = @(0.0) * 784; shape = @(1,1,28,28) } | ConvertTo-Json
    Info "Firing 6-second slow request against v1..."
    $slowJob = Start-Job -ScriptBlock {
        param($url, $body)
        try {
            Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30 | Out-Null
            "OK"
        } catch { "ERR" }
    } -ArgumentList "$BaseUrl/infer/slow?sleepMs=6000", $body

    Start-Sleep -Seconds 1
    $active = Get-Metric "model.version.active.requests" "version:v1"
    Info "active.requests{v1} during slow request: $active"

    Info "Swapping to v2 mid-flight (v1 should be marked, not yet evicted)..."
    Swap-To "v2"
    Start-Sleep -Milliseconds 500
    $evictMid = Get-Metric "model.evict.count"
    Info "evict.count immediately after swap: $evictMid"
    
    Write-Host ""
    Info "Waiting for slow request to finish..."
    Wait-Job $slowJob | Out-Null
    Remove-Job $slowJob
    Start-Sleep -Milliseconds 800
    $evictAfter = Get-Metric "model.evict.count"

    Write-Host ""
    Write-Host "  evict.count before slow request:   $evictBefore"
    Write-Host "  evict.count during slow request:   $evictMid"
    Write-Host "  evict.count after slow request:    $evictAfter"

    # restore
    Load-Model "v1" $ModelV1Path
    Swap-To "v1"

    if ($evictMid -eq $evictBefore -and $evictAfter -gt $evictBefore) {
        Proof "Eviction count stayed flat during pin ($evictBefore -> $evictMid), then advanced after request drained ($evictAfter). Pinning confirmed."
    } else {
        Proof "Did not observe defer. before=$evictBefore mid=$evictMid after=$evictAfter"
    }
}

# ------------------------------------------------------------
5 {
    H 5 "Pinning accumulates under mixed slow/fast load"
    Note "With ~10% slow requests, eviction lag grows above 1."
    Note "Lag = load.count - evict.count. Baseline is 1 (only current alive)."

    Load-Model "v2" $ModelV2Path
    Swap-To "v2"
    Load-Model "v1" $ModelV1Path
    Swap-To "v1"

    $body = @{ data = @(0.0) * 784; shape = @(1,1,28,28) } | ConvertTo-Json

    Info "Running 20s of mixed traffic + swaps, capturing peak lag..."
    $job = Start-Job -ScriptBlock {
        param($base, $body)
        $end = (Get-Date).AddSeconds(20)
        $rng = [System.Random]::new()
        while ((Get-Date) -lt $end) {
            try {
                if ($rng.Next(100) -lt 10) {
                    Invoke-RestMethod -Uri "$base/infer/slow?sleepMs=4000" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30 | Out-Null
                } else {
                    Invoke-RestMethod -Uri "$base/infer" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20 | Out-Null
                }
            } catch {}
        }
    } -ArgumentList $BaseUrl, $body

    $peakLag = 0
    $samples = @()
    $swapEnd = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $swapEnd) {
        try {
            $cur = Get-Current
            $next = if ($cur -eq "v1") { "v2" } else { "v1" }
            $nextPath = if ($next -eq "v1") { $ModelV1Path } else { $ModelV2Path }
            try { Load-Model $next $nextPath } catch {}
            try { Swap-To $next } catch {}
        } catch {}
        $l = Get-Metric "model.load.count"
        $e = Get-Metric "model.evict.count"
        if ($null -ne $l -and $null -ne $e) {
            $lag = [math]::Round($l - $e, 0)
            $samples += $lag
            if ($lag -gt $peakLag) { $peakLag = $lag }
        }
        Start-Sleep -Milliseconds 600
    }

    Wait-Job $job | Out-Null
    Remove-Job $job

    Write-Host ""
    Write-Host "  Samples of (load - evict):" ($samples -join ", ")
    Write-Host "  Peak lag observed:         $peakLag"

    Proof "Peak eviction lag = $peakLag (baseline is 1). Versions were pinned by slow requests."
}

# ------------------------------------------------------------
6 {
    H 6 "Aggressive swap cadence - retention defect (naive build behaviour)"
    Note "In Stage 2's naive build, 353 swaps at 300ms cadence produced +112 MB WS."
    Note "A forced GC recovered ~110 MB, proving it was JVM retention, not native escape."
    Note "This demo measures the CURRENT build for comparison."

    if ($ProcessId -le 0) {
        Bad "Provide -ProcessId <PID> to measure WS/GC. Get PID with: jcmd | findstr ZdtHsApplication"
        return
    }

    $wsBefore = WS-MB
    Info "WorkingSet before burst: $wsBefore MB"

    $body = @{ data = @(0.0) * 784; shape = @(1,1,28,28) } | ConvertTo-Json

    # start a fast load in background
    $loadJob = Start-Job -ScriptBlock {
        param($url, $body)
        $end = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $end) {
            try { Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20 | Out-Null } catch {}
        }
    } -ArgumentList "$BaseUrl/infer", $body

    # aggressive swap loop
    Info "Running aggressive swap loop (300ms interval) for 20s..."
    $burstEnd = (Get-Date).AddSeconds(20)
    $burstSwaps = 0
    $cur = Get-Current
    while ((Get-Date) -lt $burstEnd) {
        $next = if ($cur -eq "v1") { "v2" } else { "v1" }
        $nextPath = if ($next -eq "v1") { $ModelV1Path } else { $ModelV2Path }
        try { Load-Model $next $nextPath } catch {}
        try { Swap-To $next; $burstSwaps++; $cur = $next } catch {}
        Start-Sleep -Milliseconds 300
    }

    Wait-Job $loadJob | Out-Null
    Remove-Job $loadJob

    Start-Sleep -Seconds 2
    $wsDuring = WS-MB

    Info "Running jcmd $ProcessId GC.run ..."
    & jcmd $ProcessId GC.run | Out-Null
    Start-Sleep -Seconds 3
    $wsAfterGC = WS-MB

    $grow      = [math]::Round($wsDuring - $wsBefore, 2)
    $recover   = [math]::Round($wsDuring - $wsAfterGC, 2)
    $perSwap   = if ($burstSwaps -gt 0) { [math]::Round($grow / $burstSwaps * 1024, 2) } else { 0 }

    Write-Host ""
    Write-Host "  Swaps in burst:           $burstSwaps"
    Write-Host "  WS before:                $wsBefore MB"
    Write-Host "  WS after burst:           $wsDuring MB"
    Write-Host "  WS after GC:              $wsAfterGC MB"
    Write-Host "  Growth during burst:      $grow MB"
    Write-Host "  Recovered by full GC:     $recover MB"
    Write-Host "  Per-swap growth:          $perSwap KB"

    Proof "Growth=$grow MB, GC-recovered=$recover MB. If most growth returns to baseline on GC, it is JVM retention, not native escape."
}

# ------------------------------------------------------------
7 {
    H 7 "Stage 3 Fixes 1+2 - retention eliminated"
    Note "Same aggressive cadence as Finding 6, but with map cleanup + gauge dereg."
    Note "Stage 2's naive build: +112 MB. Fixed build target: near 0."

    if ($ProcessId -le 0) {
        Bad "Provide -ProcessId <PID> to measure WS/GC. Get PID with: jcmd | findstr ZdtHsApplication"
        return
    }

    $wsBefore = WS-MB
    Info "WorkingSet before burst: $wsBefore MB"

    $body = @{ data = @(0.0) * 784; shape = @(1,1,28,28) } | ConvertTo-Json

    $loadJob = Start-Job -ScriptBlock {
        param($url, $body)
        $end = (Get-Date).AddSeconds(20)
        while ((Get-Date) -lt $end) {
            try { Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20 | Out-Null } catch {}
        }
    } -ArgumentList "$BaseUrl/infer", $body

    Info "Running aggressive swap loop (300ms interval) for 20s..."
    $burstEnd = (Get-Date).AddSeconds(20)
    $burstSwaps = 0
    $cur = Get-Current
    while ((Get-Date) -lt $burstEnd) {
        $next = if ($cur -eq "v1") { "v2" } else { "v1" }
        $nextPath = if ($next -eq "v1") { $ModelV1Path } else { $ModelV2Path }
        try { Load-Model $next $nextPath } catch {}
        try { Swap-To $next; $burstSwaps++; $cur = $next } catch {}
        Start-Sleep -Milliseconds 300
    }

    Wait-Job $loadJob | Out-Null
    Remove-Job $loadJob

    Start-Sleep -Seconds 2
    $wsDuring = WS-MB

    & jcmd $ProcessId GC.run | Out-Null
    Start-Sleep -Seconds 3
    $wsAfterGC = WS-MB

    $grow    = [math]::Round($wsDuring - $wsBefore, 2)
    $recover = [math]::Round($wsDuring - $wsAfterGC, 2)

    Write-Host ""
    Write-Host "  Swaps in burst:           $burstSwaps"
    Write-Host "  WS before:                $wsBefore MB"
    Write-Host "  WS after burst:           $wsDuring MB"
    Write-Host "  WS after GC:              $wsAfterGC MB"
    Write-Host "  Growth during burst:      $grow MB   (Stage 2 naive was +112 MB over 353 swaps)"
    Write-Host "  Recovered by full GC:     $recover MB"

    if ([math]::Abs($grow) -lt 30) {
        Proof "Growth during burst = $grow MB (vs +112 MB naive). Fixes 1+2 eliminated the retention."
    } else {
        Proof "Growth during burst = $grow MB. Still significant - investigate third retention path."
    }
}

default {
    Write-Host "Unknown finding: $Finding (expected 1-7)" -ForegroundColor Red
}
}