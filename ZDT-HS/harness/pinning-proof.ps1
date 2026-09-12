param(
    [string]$BaseUrl          = "http://localhost:8081",
    [string]$ModelV1Path      = "src/main/resources/models/model-v1.onnx",
    [string]$ModelV2Path      = "src/main/resources/models/model-v2.onnx",
    [int]$SlowSleepMs         = 10000
)

$body = @{
    data  = @(0.0) * 784
    shape = @(1, 1, 28, 28)
} | ConvertTo-Json

function Query($name, $tag = $null) {
    $url = "$BaseUrl/actuator/metrics/$name"
    if ($tag) { $url += "?tag=$tag" }
    try {
        $r = Invoke-RestMethod $url -TimeoutSec 5
        return $r.measurements[0].value
    } catch {
        return "n/a"
    }
}

Write-Host "=== Step A: reload both versions so both are alive ==="
Invoke-RestMethod -Uri "$BaseUrl/admin/models/load?versionId=v1&path=$ModelV1Path" -Method Post | Out-Null
Invoke-RestMethod -Uri "$BaseUrl/admin/models/load?versionId=v2&path=$ModelV2Path" -Method Post | Out-Null
Invoke-RestMethod -Uri "$BaseUrl/admin/models/swap?versionId=v1" -Method Post | Out-Null
Write-Host "Current version is now v1. Evict count: $(Query 'model.evict.count')"

Write-Host ""
Write-Host "=== Step B: fire slow request against v1 (sleep=$SlowSleepMs ms) in background ==="
$job = Start-Job -ScriptBlock {
    param($url, $body)
    try {
        Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json" -TimeoutSec 60 | Out-Null
        "OK"
    } catch {
        "ERR: $($_.Exception.Message)"
    }
} -ArgumentList "$BaseUrl/infer/slow?sleepMs=$SlowSleepMs", $body

Start-Sleep -Seconds 1
Write-Host "Slow request should now be in-flight."
Write-Host "  active.requests{version=v1}     = $(Query 'model.version.active.requests' 'version:v1')"
Write-Host "  marked.for.eviction{version=v1} = $(Query 'model.version.marked.for.eviction' 'version:v1')"

Write-Host ""
Write-Host "=== Step C: swap to v2 mid-flight. v1 should be MARKED but NOT evicted. ==="
Invoke-RestMethod -Uri "$BaseUrl/admin/models/swap?versionId=v2" -Method Post | Out-Null

Write-Host "Immediately after swap:"
Write-Host "  active.requests{version=v1}     = $(Query 'model.version.active.requests' 'version:v1')"
Write-Host "  marked.for.eviction{version=v1} = $(Query 'model.version.marked.for.eviction' 'version:v1')"
Write-Host "  model.evict.count               = $(Query 'model.evict.count')      <- should NOT have incremented yet"

Write-Host ""
Write-Host "=== Step D: wait for slow request to finish ==="
Wait-Job $job | Out-Null
$result = Receive-Job $job
Remove-Job $job | Out-Null
Write-Host "Slow request result: $result"

Start-Sleep -Milliseconds 500
Write-Host ""
Write-Host "After slow request completes:"
Write-Host "  active.requests{version=v1}     = $(Query 'model.version.active.requests' 'version:v1')"
Write-Host "  marked.for.eviction{version=v1} = $(Query 'model.version.marked.for.eviction' 'version:v1')"
Write-Host "  model.evict.count               = $(Query 'model.evict.count')      <- should NOW have incremented"