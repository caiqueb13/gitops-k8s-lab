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
foreach ($tool in @('kind', 'kubectl', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' was not found in PATH. Install it and retry."
    }
}

Write-Host "Creating Kind cluster '$Name' (k3d is the lighter default for this lab)..." -ForegroundColor Cyan
& kind create cluster --name $Name --wait 5m
if ($LASTEXITCODE -ne 0) { throw "kind cluster create failed with exit code $LASTEXITCODE." }

$Context = "kind-$Name"
& (Join-Path $PSScriptRoot 'bootstrap-context.ps1') -Name $Name -Context $Context -GitUrl $GitUrl
