[CmdletBinding()]
param([switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ObsDir = Join-Path $RepoRoot 'observability'
$StateDir = Join-Path $ObsDir '.state'
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

foreach ($tool in @('docker', 'kubectl', 'helm')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found in PATH." }
}
$Python = Get-Command python -ErrorAction SilentlyContinue
if (-not $Python) { $Python = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not $Python) { throw 'Python 3 is required to run the local metrics collector.' }
& docker compose version *> $null
if ($LASTEXITCODE -ne 0) { throw 'Docker Compose v2 is required.' }

$PidPath = Join-Path $StateDir 'collector.pid'
if (Test-Path $PidPath) {
    $ExistingPid = [int](Get-Content -LiteralPath $PidPath -Raw)
    $ExistingCommand = Get-CimInstance Win32_Process -Filter "ProcessId=$ExistingPid" -ErrorAction SilentlyContinue
    if ($ExistingCommand -and $ExistingCommand.CommandLine -like '*observability*collector.py*') {
        Write-Host "Metrics collector is already running (PID $ExistingPid)." -ForegroundColor Yellow
    } else {
        Remove-Item -LiteralPath $PidPath -Force
    }
}
if (-not (Test-Path $PidPath)) {
    $PreviousBind = $env:OBSERVABILITY_BIND
    $env:OBSERVABILITY_BIND = '0.0.0.0'
    $Collector = Join-Path $ObsDir 'collector.py'
    $OutLog = Join-Path $StateDir 'collector.log'
    $ErrLog = Join-Path $StateDir 'collector-error.log'
    $Process = Start-Process -FilePath $Python.Source -ArgumentList @("`"$Collector`"") -WorkingDirectory $RepoRoot -PassThru -WindowStyle Hidden -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
    $env:OBSERVABILITY_BIND = $PreviousBind
    Set-Content -LiteralPath $PidPath -Value $Process.Id -NoNewline
    Start-Sleep -Seconds 2
    if ($Process.HasExited) { Remove-Item $PidPath -Force; throw "Metrics collector exited. See $ErrLog" }
}

Push-Location $ObsDir
try {
    & docker compose up -d
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose could not start Prometheus and Grafana.' }
} finally { Pop-Location }

$Ready = $false
for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
    try { $null = Invoke-WebRequest -Uri 'http://localhost:3000/api/health' -TimeoutSec 2; $Ready = $true; break } catch { Start-Sleep -Seconds 2 }
}
if (-not $Ready) { throw 'Grafana did not become ready at http://localhost:3000. Check Docker Compose logs.' }
Write-Host 'Grafana dashboard: http://localhost:3000/d/gitops-lab-fleet/gitops-lab-fleet-compliance' -ForegroundColor Green
Write-Host 'Default local login: admin / admin. Change it on first login. Data is retained in Docker volumes until explicitly removed.' -ForegroundColor Yellow
if (-not $NoBrowser) { Start-Process 'http://localhost:3000/d/gitops-lab-fleet/gitops-lab-fleet-compliance' }
