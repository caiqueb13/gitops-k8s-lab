[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[^\s]+$')]
    [string]$GitUrl
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('k3d', 'kubectl', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' was not found in PATH. Install it and retry."
    }
}

Write-Host "Creating local K3s cluster '$Name' with k3d..." -ForegroundColor Cyan
& k3d cluster create $Name --wait --timeout 5m
if ($LASTEXITCODE -ne 0) { throw "k3d cluster create failed with exit code $LASTEXITCODE." }

$Context = "k3d-$Name"
& (Join-Path $PSScriptRoot 'bootstrap-context.ps1') -Name $Name -Context $Context -GitUrl $GitUrl
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Cluster bootstrap failed with exit code $LASTEXITCODE." }
