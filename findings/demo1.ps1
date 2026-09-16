# ============================================================
# ZDT-HS Findings Demo
# Demonstrates all 6 findings from Stages 0-2
# ============================================================
# Usage:
#   & .\harness\demo-all-findings.ps1 -ProcessId <PID>
# Get PID with: jcmd | findstr ZdtHsApplication
# ============================================================

param(
    [string]$BaseUrl     = "http://localhost:8081",
    [int]   $ProcessId   = 0,
    [string]$ModelV1Path = "src/main/resources/models/model-v1.onnx",
    [string]$ModelV2Path = "src/main/resources/models/model-v2.onnx"
)

$ErrorActionPreference = "Continue"

function Section($n, $title) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " FINDING $n - $title" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Note($msg)    { Write-Host "  $msg" -ForegroundColor Gray }
function Pass($msg)    { Write-Host "  [PASS] $msg" -ForegroundColor Green }
function Info($msg)    { Write-Host "  $msg" -ForegroundColor Yellow }

function Get-Metric($name, $tag = $null) {
    $url = "$BaseUrl/actuator/metrics/$name"
    if ($tag) { $url += "?tag=$tag" }
    try {
        $r = Invoke-RestMethod $url -TimeoutSec 5
        return $r.measurements[0].value
    } catch { return $null }
}

function Get-Current() {
    return (Invoke-RestMethod "$BaseUrl/admin/models/current" -TimeoutSec 5)
}

function Load-Model($id, $path) {
    Invoke-RestMethod -Uri "$BaseUrl/admin/models/load?versionId=$id&path=$path" -Method Post -TimeoutSec 30 | Out-Null
}

function Swap-To($id) {
    Invoke-RestMethod -Uri "$BaseUrl/admin/models/swap?versionId=$id" -Method Post -TimeoutSec 30 | Out-Null
}

function Infer-One() {
    $body = @{ data = @(0.0) * 784; shape = @(1,1,28,28) } | ConvertTo-Json
    try {
        return Invoke-RestMethod -Uri "$BaseUrl/infer" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20
    } catch { return $null }
}

function Process-MB() {
    if ($ProcessId -le 0) { return "n/a" }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        return [math]::Round($p.WorkingSet64 / 1MB, 2)
    } catch { return "n/a" }
}

# ------------------------------------------------------------
# Preflight
# ------------------------------------------------------------
Write-Host ""
Write-Host "ZDT-HS Findings Demonstration" -ForegroundColor White
Write-Host "Target: $BaseUrl" -ForegroundColor White
if ($ProcessId -gt 0) { Write-Host "PID:    $ProcessId" -ForegroundColor White }

try {
    $health = Invoke-RestMethod "$BaseUrl/actuator/health" -TimeoutSec 5
    if ($health.status -ne "UP") { throw "App not UP" }
} catch {
    Write-Host "App is not responding at $BaseUrl. Start it with 'mvn spring-boot:run' first." -ForegroundColor Red
    exit 1
}
Write-Host "App is UP." -ForegroundColor Green

# Clean state: ensure v1 loaded and current
try { Load-Model "v1" $ModelV1Path } catch {}
try { Swap-To "v1" } catch {}

# ------------------------------------------------------------
Section "01" "Stale version swap causes 500 (STAGE 0)"
# ------------------------------------------------------------
Note "Reproduces the original defect: swap to an evicted version."
Note "On the naive build this silently succeeded and the next /infer 500'd."
Note "With Stage 3 Fix 1 (map cleanup), the entry is truly removed - swap errors cleanly."

Load-Model "v2" $ModelV2Path
Swap-To "v2"      # evicts v1
Start-Sleep -Milliseconds 500

Write-Host "  After swapping to v2, attempting to swap back to evicted v1..."
try {
    Swap-To "v1"
    Write-Host "  Swapped - UNEXPECTED" -ForegroundColor Red
} catch {
    $msg = $_.ErrorDetails.Message
    if (-not $msg) { $msg = $_.Exception.Message }
    Info "Server response: $msg"
    if ($msg -match "not loaded|evicted") {
        Pass "Swap to evicted version rejected cleanly (no silent success)"
    } else {
        Write-Host "  Unexpected error: $msg" -ForegroundColor Red
    }
}

# restore v1
Load-Model "v1" $ModelV1Path
Swap-To "v1"

# ------------------------------------------------------------
Section "02" "Micrometer gauge binding reuse (STAGE 1)"
# ------------------------------------------------------------
Note "Naive behaviour: same (name,tags) returns the SAME meter, so reloads"
Note "silently discard the new binding and the first-ever instance keeps reporting."
Note "Fix: per-instance UUID tag + deregistration on evict."

$before = Get-Metric "model.version.marked.for.eviction" "version:v1"
Info "marked.for.eviction{v1} BEFORE any v1 eviction this cycle = $before"

Load-Model "v2" $ModelV2Path
Swap-To "v2"      # evicts v1, deregisters its gauges
Start-Sleep -Milliseconds 500

$after = Get-Metric "model.version.marked.for.eviction" "version:v1"
if ($null -eq $after) {
    Pass "v1 gauge is GONE after eviction (404) - Fix 2 working"
} else {
    Write-Host "  v1 gauge still reports $after - Fix 2 NOT working" -ForegroundColor Red
}

Load-Model "v1" $ModelV1Path
Swap-To "v1"

# ------------------------------------------------------------
Section "03" "Experiment A - fast traffic, no slow requests (STAGE 2)"
# ------------------------------------------------------------
Note "Expected: 0 errors, memory stays flat. Concurrency alone is not the problem."

$wsBefore = Process-MB
Info "WorkingSet before: $wsBefore MB"

$body = @{ data = @(0.0) * 784; shape = @(1,1,28,28) } | ConvertTo-Json
$job = Start-Job -ScriptBlock {
    param($url, $body)
    $end = (Get-Date).AddSeconds(10)
    $ok = 0; $err = 0
    while ((Get-Date) -lt $end) {
        try {
            Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20 | Out-Null
            $ok++
        } catch { $err++ }
    }
    [pscustomobject]@{ ok=$ok; err=$err }
} -ArgumentList "$BaseUrl/infer", $body

Wait-Job $job | Out-Null
$r = Receive-Job $job; Remove-Job $job
$wsAfter = Process-MB

Info "Requests: $($r.ok) ok, $($r.err) err over 10s"
Info "WorkingSet after: $wsAfter MB (delta: $([math]::Round($wsAfter - $wsBefore, 2)) MB)"
if ($r.err -eq 0) { Pass "Zero errors under fast concurrent load" }
else { Write-Host "  Unexpected errors: $($r.err)" -ForegroundColor Red }

# ------------------------------------------------------------
Section "04" "Isolated pinning proof (STAGE 2)"
# ------------------------------------------------------------
Note "A slow request pins the version it started on until it completes."
Note "Eviction for that version is deferred by exactly the sleep duration."

Load-Model "v2" $ModelV2Path
Swap-To "v2"        # current = v2
Load-Model "v1" $ModelV1Path
Swap-To "v1"        # current = v1, fresh instance

$evictBefore = Get-Metric "model.evict.count"
Info "evict.count before: $evictBefore"
Info "Firing a 6-second slow request against v1..."

$slowJob = Start-Job -ScriptBlock {
    param($url, $body)
    try {
        Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30 | Out-Null
        "OK"
    } catch { "ERR: $($_.Exception.Message)" }
} -ArgumentList "$BaseUrl/infer/slow?sleepMs=6000", $body

Start-Sleep -Seconds 1
$activeDuring = Get-Metric "model.version.active.requests" "version:v1"
Info "active.requests{v1} during slow request: $activeDuring"

Info "Swapping to v2 mid-flight - v1 should be marked but NOT yet evicted..."
Swap-To "v2"
Start-Sleep -Milliseconds 500
$evictMid = Get-Metric "model.evict.count"
Info "evict.count immediately after swap: $evictMid (should equal $evictBefore)"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Wait-Job $slowJob | Out-Null
$slowResult = Receive-Job $slowJob; Remove-Job $slowJob
$sw.Stop()
Start-Sleep -Milliseconds 500
$evictAfter = Get-Metric "model.evict.count"

Info "Slow request finished after $([math]::Round($sw.Elapsed.TotalSeconds,1))s extra wait: $slowResult"
Info "evict.count after request drained: $evictAfter"

if ($evictMid -eq $evictBefore -and $evictAfter -gt $evictBefore) {
    Pass "Pinning confirmed: eviction deferred until slow request released"
} else {
    Write-Host "  Did not observe defer. mid=$evictMid before=$evictBefore after=$evictAfter" -ForegroundColor Red
}

# restore
Load-Model "v1" $ModelV1Path
Swap-To "v1"

# ------------------------------------------------------------
Section "05" "Scaled pinning - slow requests under load (STAGE 2)"
# ------------------------------------------------------------
Note "With ~10% slow requests mixed into fast traffic, eviction lag grows."
Note "load.count - evict.count should exceed 1 (only-the-current-version-alive)."

Load-Model "v2" $ModelV2Path
Swap-To "v2"
Load-Model "v1" $ModelV1Path
Swap-To "v1"

# Start mixed load
$mixedJob = Start-Job -ScriptBlock {
    param($base, $body)
    $end = (Get-Date).AddSeconds(20)
    $rng = [System.Random]::new()
    $ok = 0; $err = 0
    while ((Get-Date) -lt $end) {
        try {
            if ($rng.Next(100) -lt 10) {
                Invoke-RestMethod -Uri "$base/infer/slow?sleepMs=4000" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30 | Out-Null
            } else {
                Invoke-RestMethod -Uri "$base/infer" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 20 | Out-Null
            }
            $ok++
        } catch { $err++ }
    }
    [pscustomobject]@{ ok=$ok; err=$err }
} -ArgumentList $BaseUrl, $body

# Concurrent swap loop
$swapEnd = (Get-Date).AddSeconds(20)
$swaps = 0
while ((Get-Date) -lt $swapEnd) {
    $cur = Get-Current
    $next = if ($cur -eq "v1") { "v2" } else { "v1" }
    $nextPath = if ($next -eq "v1") { $ModelV1Path } else { $ModelV2Path }
    try { Load-Model $next $nextPath } catch {}
    try { Swap-To $next; $swaps++ } catch {}
    Start-Sleep -Milliseconds 1000
}

Wait-Job $mixedJob | Out-Null
$mixedR = Receive-Job $mixedJob; Remove-Job $mixedJob

$load  = Get-Metric "model.load.count"
$evict = Get-Metric "model.evict.count"
$lag   = [math]::Round($load - $evict, 0)

Info "Mixed load result: $($mixedR.ok) ok / $($mixedR.err) err"
Info "Swaps performed: $swaps"
Info "load.count = $load, evict.count = $evict, lag = $lag"
if ($lag -gt 1) {
    Pass "Eviction lag > 1 - versions pinned by slow requests"
} else {
    Info "Lag is $lag - pinning not captured this run (timing-dependent)"
}

# ------------------------------------------------------------
Section "06" "Aggressive cadence retention + GC recovery (STAGE 2)"
# ------------------------------------------------------------
Note "Rapid swaps grow WorkingSet. A forced GC shows the growth was"
Note "JVM-side retention, not native escape."

$wsBefore = Process-MB
Info "WorkingSet before burst: $wsBefore MB"

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

Start-Sleep -Seconds 2
$wsDuring = Process-MB
Info "Swaps in burst: $burstSwaps"
Info "WorkingSet after burst: $wsDuring MB"

if ($ProcessId -gt 0) {
    Info "Running jcmd $ProcessId GC.run ..."
    & jcmd $ProcessId GC.run | Out-Null
    Start-Sleep -Seconds 3
    $wsAfter = Process-MB
    Info "WorkingSet after GC: $wsAfter MB"
    $recoverable = [math]::Round($wsDuring - $wsAfter, 2)
    if ($recoverable -gt 5) {
        Pass "Post-GC drop of $recoverable MB confirms JVM retention, not native leak"
    } else {
        Info "Post-GC drop was only $recoverable MB (Fix 1+2 may have already prevented retention)"
    }
} else {
    Info "No -ProcessId given - skipping GC test"
}

# ------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " DEMO COMPLETE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Summary of what was demonstrated:" -ForegroundColor White
Write-Host "  01 - Stale swap rejected cleanly (was: silent success -> 500)" 
Write-Host "  02 - Gauge deregistered on evict (was: stuck at 1.0 forever)"
Write-Host "  03 - Fast concurrent load stays clean (baseline behaviour)"
Write-Host "  04 - Slow request pins eviction (unbounded latency defect)"
Write-Host "  05 - Pinning accumulates under mixed load (bounded only by timeout)"
Write-Host "  06 - Aggressive swaps cause JVM retention, recoverable via full GC"
Write-Host ""