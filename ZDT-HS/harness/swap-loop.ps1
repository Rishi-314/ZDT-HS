param(
    [string]$BaseUrl         = "http://localhost:8081",
    [int]$DurationSeconds    = 30,
    [int]$IntervalMs         = 2000,
    [string]$ModelV1Path     = "src/main/resources/models/model-v1.onnx",
    [string]$ModelV2Path     = "src/main/resources/models/model-v2.onnx"
)

$end = (Get-Date).AddSeconds($DurationSeconds)
$current = "v1"
$swaps = 0
$errors = 0
$errorsShown = 0
$t0 = Get-Date

Write-Host ">>> Swap loop: every $IntervalMs ms for $DurationSeconds s"

while ((Get-Date) -lt $end) {
    $next = if ($current -eq "v1") { "v2" } else { "v1" }
    $nextPath = if ($next -eq "v1") { $ModelV1Path } else { $ModelV2Path }

    try {
        Invoke-RestMethod -Uri "$BaseUrl/admin/models/load?versionId=$next&path=$nextPath" -Method Post -TimeoutSec 30 | Out-Null
    } catch {
        # Might already be loaded; ignore silently
    }

    try {
        Invoke-RestMethod -Uri "$BaseUrl/admin/models/swap?versionId=$next" -Method Post -TimeoutSec 30 | Out-Null
        $swaps++
        $current = $next
    } catch {
        $errors++
        if ($errorsShown -lt 5) {
            Write-Host "SWAP ERROR: $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) {
                Write-Host "  Details: $($_.ErrorDetails.Message)"
            }
            $errorsShown++
        }
    }

    Start-Sleep -Milliseconds $IntervalMs
}

$elapsed = ((Get-Date) - $t0).TotalSeconds
Write-Host ""
Write-Host "===== Swap loop summary ====="
Write-Host "Duration:        $([math]::Round($elapsed, 1)) s"
Write-Host "Swaps completed: $swaps"
Write-Host "Errors:          $errors"
Write-Host "Avg interval:    $([math]::Round($elapsed * 1000 / [math]::Max($swaps,1), 0)) ms"