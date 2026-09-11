param(
    [string]$BaseUrl   = "http://localhost:8081",
    [string]$Label     = "snapshot",
    [int]$ProcessId    = 0
)

$ts = Get-Date -Format "yyyyMMdd-HHmmss"
$dir = "harness/results"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$out = "$dir/$Label-$ts.txt"

function Get-Metric($name, $tag = $null) {
    $url = "$BaseUrl/actuator/metrics/$name"
    if ($tag) { $url += "?tag=$tag" }
    try {
        $r = Invoke-RestMethod $url -TimeoutSec 10
        return $r.measurements[0].value
    } catch {
        return "n/a"
    }
}

$lines = @()
$lines += "=== Snapshot: $Label @ $ts ==="
$lines += ""
$lines += "--- Counters ---"
$lines += "model.load.count           = $(Get-Metric 'model.load.count')"
$lines += "model.swap.count           = $(Get-Metric 'model.swap.count')"
$lines += "model.evict.count          = $(Get-Metric 'model.evict.count')"
$lines += ""
$lines += "--- Gauges per version ---"
foreach ($v in @('v1','v2')) {
    $active = Get-Metric 'model.version.active.requests' "version:$v"
    $marked = Get-Metric 'model.version.marked.for.eviction' "version:$v"
    $lines += "active.requests{version=$v}            = $active"
    $lines += "marked.for.eviction{version=$v}        = $marked"
}

if ($ProcessId -gt 0) {
    $lines += ""
    $lines += "--- JVM process memory ---"
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction Stop
        $lines += "WorkingSet64               = $([math]::Round($p.WorkingSet64 / 1MB, 2)) MB"
        $lines += "PrivateMemorySize64        = $([math]::Round($p.PrivateMemorySize64 / 1MB, 2)) MB"
    } catch {
        $lines += "Process $ProcessId not found"
    }

    $lines += ""
    $lines += "--- NMT Total ---"
    try {
        $nmtOut = & jcmd $ProcessId VM.native_memory summary 2>&1
        $totalLine = $nmtOut | Select-String "Total:" | Select-Object -First 1
        if ($totalLine) {
            $lines += $totalLine.ToString().Trim()
        } else {
            $lines += "NMT returned no Total line. Raw output first 3 lines:"
            $lines += ($nmtOut | Select-Object -First 3) -join " | "
        }
    } catch {
        $lines += "NMT command failed: $($_.Exception.Message)"
    }
}

$lines | Tee-Object -FilePath $out
Write-Host ""
Write-Host ">>> Saved to $out"