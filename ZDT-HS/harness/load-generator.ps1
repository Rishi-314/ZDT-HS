param(
    [string]$BaseUrl       = "http://localhost:8081",
    [int]$Workers          = 8,
    [int]$DurationSeconds  = 30,
    [int]$SlowPercent      = 0,
    [int]$SlowSleepMs      = 5000
)

$body = @{
    data  = @(0.0) * 784
    shape = @(1, 1, 28, 28)
} | ConvertTo-Json

$jobScript = {
    param($BaseUrl, $Body, $DurationSeconds, $SlowPercent, $SlowSleepMs)

    $end = (Get-Date).AddSeconds($DurationSeconds)
    $ok = 0
    $err = 0
    $rng = [System.Random]::new()
    $errorsShown = 0

    while ((Get-Date) -lt $end) {
        try {
            if ($SlowPercent -gt 0 -and $rng.Next(100) -lt $SlowPercent) {
                $url = "$BaseUrl/infer/slow?sleepMs=$SlowSleepMs"
            } else {
                $url = "$BaseUrl/infer"
            }
            Invoke-RestMethod -Uri $url -Method Post -Body $Body -ContentType "application/json" -TimeoutSec 60 | Out-Null
            $ok++
        } catch {
            $err++
            if ($errorsShown -lt 3) {
                Write-Host "WORKER ERROR: $($_.Exception.Message)"
                if ($_.ErrorDetails.Message) {
                    Write-Host "  Details: $($_.ErrorDetails.Message)"
                }
                $errorsShown++
            }
        }
    }
    [pscustomobject]@{ ok = $ok; err = $err }
}

Write-Host ">>> Starting $Workers workers for $DurationSeconds s (slow=$SlowPercent%)..."
$jobs = 1..$Workers | ForEach-Object {
    Start-Job -ScriptBlock $jobScript -ArgumentList $BaseUrl, $body, $DurationSeconds, $SlowPercent, $SlowSleepMs
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$jobs | Wait-Job | Out-Null
$sw.Stop()

$results = $jobs | Receive-Job
$jobs | Remove-Job

$totalOk  = ($results | Measure-Object -Property ok  -Sum).Sum
$totalErr = ($results | Measure-Object -Property err -Sum).Sum

Write-Host ""
Write-Host "===== Load generator summary ====="
Write-Host "Duration:        $($sw.Elapsed.TotalSeconds.ToString('0.0')) s"
Write-Host "Workers:         $Workers"
Write-Host "Successful:      $totalOk"
Write-Host "Errors:          $totalErr"
if ($sw.Elapsed.TotalSeconds -gt 0) {
    Write-Host "Throughput:      $([math]::Round($totalOk / $sw.Elapsed.TotalSeconds, 1)) req/s"
}