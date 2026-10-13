[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Context,
    [Parameter(Mandatory = $true)][ValidatePattern('^https://[^\s]+$')][string]$GitUrl,
    [string]$ClusterName,
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$GitSecretName
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('kubectl', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found in PATH." }
}
if (-not $ClusterName) {
    $ClusterName = ($Context.ToLowerInvariant() -replace '[^a-z0-9-]+', '-' -replace '^-+|-+$', '')
    if ($ClusterName.Length -gt 50) { $ClusterName = $ClusterName.Substring(0, 50).TrimEnd('-') }
}
if ($ClusterName -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') { throw "Context '$Context' could not be converted to a valid cluster name. Supply -ClusterName explicitly." }

$Bootstrap = Join-Path $PSScriptRoot 'bootstrap-context.ps1'
& $Bootstrap -Name $ClusterName -Context $Context -GitUrl $GitUrl -GitSecretName $GitSecretName
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Flux onboarding failed for '$Context'." }
Write-Host "Onboarding complete for '$Context'. Add its exact context to observability/contexts.txt to include it in Grafana." -ForegroundColor Green
