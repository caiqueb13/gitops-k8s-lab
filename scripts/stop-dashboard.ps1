[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ObsDir = Join-Path $RepoRoot 'observability'
$PidPath = Join-Path $ObsDir '.state/collector.pid'
if (Test-Path $PidPath) {
    $CollectorPid = [int](Get-Content -LiteralPath $PidPath -Raw)
    $CollectorCommand = Get-CimInstance Win32_Process -Filter "ProcessId=$CollectorPid" -ErrorAction SilentlyContinue
    if ($CollectorCommand -and $CollectorCommand.CommandLine -like '*observability*collector.py*') {
        Stop-Process -Id $CollectorPid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $PidPath -Force
}
Push-Location $ObsDir
try { & docker compose down; if ($LASTEXITCODE -ne 0) { throw 'Docker Compose shutdown failed.' } }
finally { Pop-Location }
Write-Host 'Grafana and Prometheus stopped. Historical metrics remain in Docker volumes.' -ForegroundColor Green
