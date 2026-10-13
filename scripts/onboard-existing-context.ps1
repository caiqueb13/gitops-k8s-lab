[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Context,
    [Parameter(Mandatory = $true)][ValidatePattern('^https://[^\s]+$')][string]$GitUrl,
    [string]$ClusterName,
    [string]$HubContext = 'k3d-ocm-hub',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$GitSecretName
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('kubectl', 'flux', 'clusteradm')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found in PATH." }
}
& kubectl --context $HubContext get clustermanager cluster-manager *> $null
if ($LASTEXITCODE -ne 0) { throw "OCM hub '$HubContext' is unavailable or not initialized. Run scripts/new-ocm-hub.ps1 first." }
if (-not $ClusterName) {
    $ClusterName = ($Context.ToLowerInvariant() -replace '[^a-z0-9-]+', '-' -replace '^-+|-+$', '')
    if ($ClusterName.Length -gt 50) { $ClusterName = $ClusterName.Substring(0, 50).TrimEnd('-') }
}
if ($ClusterName -notmatch '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$') { throw "Context '$Context' could not be converted to a valid OCM cluster name. Supply -ClusterName explicitly." }

$Bootstrap = Join-Path $PSScriptRoot 'bootstrap-context.ps1'
& $Bootstrap -Name $ClusterName -Context $Context -GitUrl $GitUrl -GitSecretName $GitSecretName
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Flux onboarding failed for '$Context'." }
& (Join-Path $PSScriptRoot 'register-ocm-cluster.ps1') -Context $Context -ClusterName $ClusterName -HubContext $HubContext -ManagedBy explicit
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "OCM registration failed for '$Context'." }
