[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[^\s]+$')]
    [string]$GitUrl,

    [string]$ContextPattern = '^k3d-'
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('k3d', 'kubectl', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' was not found in PATH."
    }
}

$ClustersJson = & k3d cluster list -o json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the active k3d cluster inventory.' }
$Clusters = @($ClustersJson | ConvertFrom-Json)
$Targets = @($Clusters | Where-Object { $_ -and $_.name } | ForEach-Object { "k3d-$($_.name)" } | Where-Object { $_ -match $ContextPattern })
if ($Targets.Count -eq 0) {
    Write-Host "No contexts matched '$ContextPattern'. Nothing to bootstrap." -ForegroundColor Yellow
    return
}

$Failures = [System.Collections.Generic.List[string]]::new()
foreach ($Context in $Targets) {
    $Name = $Context -replace '^k3d-', ''
    Write-Host "`n=== $Context ===" -ForegroundColor Cyan
    try {
        & (Join-Path $PSScriptRoot 'bootstrap-context.ps1') -Name $Name -Context $Context -GitUrl $GitUrl
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Bootstrap process failed with exit code $LASTEXITCODE." }
    }
    catch {
        $Failures.Add("$Context`: $($_.Exception.Message)")
        Write-Warning $Failures[$Failures.Count - 1]
    }
}

if ($Failures.Count -gt 0) {
    throw ("Fleet sync finished with {0} failure(s):`n{1}" -f $Failures.Count, ($Failures -join "`n"))
}
Write-Host "Successfully bootstrapped $($Targets.Count) matching context(s)." -ForegroundColor Green
