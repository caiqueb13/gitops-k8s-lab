[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Context,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$ClusterName,
    [string]$HubContext = 'k3d-ocm-hub',
    [ValidateSet('k3d-fleet', 'explicit')][string]$ManagedBy = 'explicit'
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('kubectl', 'clusteradm')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found in PATH." }
}
& kubectl --context $HubContext get clustermanager cluster-manager *> $null
if ($LASTEXITCODE -ne 0) { throw "OCM is not initialized or hub context '$HubContext' is unavailable. Run scripts/new-ocm-hub.ps1 first." }
& kubectl --context $Context cluster-info *> $null
if ($LASTEXITCODE -ne 0) { throw "Managed cluster context '$Context' is not reachable." }

$CurrentJson = & kubectl --context $HubContext get managedcluster $ClusterName --ignore-not-found -o json
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect OCM inventory for '$ClusterName'." }
$IsJoined = $false
if ($CurrentJson) {
    $Current = $CurrentJson | ConvertFrom-Json
    $JoinedCondition = $Current.status.conditions | Where-Object { $_.type -eq 'ManagedClusterJoined' -and $_.status -eq 'True' }
    $IsJoined = [bool]($Current.spec.hubAcceptsClient -and $JoinedCondition)
}

if (-not $IsJoined) {
    $TokenOutput = & clusteradm get token --context $HubContext 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Unable to obtain an OCM join token.' }
    $TokenText = $TokenOutput -join ' '
    $TokenMatch = [regex]::Match($TokenText, '--hub-token(?:=|\s+)(?:"([^"]+)"|(\S+))')
    $ApiMatch = [regex]::Match($TokenText, '--hub-apiserver(?:=|\s+)(?:"([^"]+)"|(\S+))')
    if (-not $TokenMatch.Success -or -not $ApiMatch.Success) { throw 'Could not parse the join token and API endpoint from clusteradm output.' }
    $Token = if ($TokenMatch.Groups[1].Success) { $TokenMatch.Groups[1].Value } else { $TokenMatch.Groups[2].Value }
    $Api = if ($ApiMatch.Groups[1].Success) { $ApiMatch.Groups[1].Value } else { $ApiMatch.Groups[2].Value }
    & clusteradm join --hub-token $Token --hub-apiserver $Api --wait --cluster-name $ClusterName --force-internal-endpoint-lookup --context $Context
    if ($LASTEXITCODE -ne 0) { throw "OCM join failed for '$Context'. Verify that the managed cluster can reach the local hub." }
    & clusteradm accept --clusters $ClusterName --context $HubContext
    if ($LASTEXITCODE -ne 0) { throw "OCM registration approval failed for '$ClusterName'." }
}

& kubectl --context $HubContext label managedcluster $ClusterName "lab.gitops/managed-by=$ManagedBy" --overwrite
if ($LASTEXITCODE -ne 0) { throw "Unable to mark OCM cluster '$ClusterName' as lab-managed." }
& kubectl --context $HubContext annotate managedcluster $ClusterName "lab.gitops/context=$Context" --overwrite
if ($LASTEXITCODE -ne 0) { throw "Unable to record context for OCM cluster '$ClusterName'." }
Write-Host "Registered '$ClusterName' ($Context) in OCM hub '$HubContext'." -ForegroundColor Green
