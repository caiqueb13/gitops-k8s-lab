[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$HubName = 'ocm-hub',

    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$SpokeName = 'ocm-demo',

    [string]$K3sImage = 'rancher/k3s:v1.34.12-k3s1'
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('k3d', 'kubectl', 'clusteradm', 'docker')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' was not found in PATH."
    }
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$HubContext = "k3d-$HubName"
$SpokeContext = "k3d-$SpokeName"
$SharedNetwork = "k3d-$HubName"

Write-Host 'Preparing the OCM hub...' -ForegroundColor Cyan
& (Join-Path $RepoRoot 'scripts/new-ocm-hub.ps1') -Name $HubName -K3sImage $K3sImage
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Could not prepare the OCM hub.' }

$null = & docker network inspect $SharedNetwork 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Expected k3d network '$SharedNetwork' was not found. The OCM hub must be created by scripts/new-ocm-hub.ps1."
}

$ClustersJson = & k3d cluster list -o json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the k3d cluster inventory.' }
$Clusters = ConvertFrom-Json -InputObject ($ClustersJson -join [Environment]::NewLine)
if (-not ($Clusters | Where-Object { $_.name -eq $SpokeName })) {
    Write-Host "Creating demo spoke '$SpokeName' on shared Docker network '$SharedNetwork'..." -ForegroundColor Cyan
    & k3d cluster create $SpokeName --image $K3sImage --network $SharedNetwork --wait --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "Failed to create demo cluster '$SpokeName'." }
}

& kubectl --context $HubContext cluster-info *> $null
if ($LASTEXITCODE -ne 0) { throw "Hub context '$HubContext' is not reachable. Make sure the hub is running." }
& kubectl --context $SpokeContext cluster-info *> $null
if ($LASTEXITCODE -ne 0) { throw "Spoke context '$SpokeContext' is not reachable. Make sure the demo cluster is running." }

$SpokeContainer = "k3d-$SpokeName-server-0"
$SpokeNetworksJson = & docker inspect $SpokeContainer --format '{{json .NetworkSettings.Networks}}'
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect demo node '$SpokeContainer'." }
$SpokeNetworks = $SpokeNetworksJson | ConvertFrom-Json
$SpokeNetworkNames = @($SpokeNetworks.PSObject.Properties | ForEach-Object { $_.Name })
if ($SharedNetwork -notin $SpokeNetworkNames) {
    throw "Demo cluster '$SpokeName' is not attached to '$SharedNetwork'. Delete only that demo cluster and rerun this script."
}

Write-Host 'Registering the demo spoke with OCM...' -ForegroundColor Cyan
& (Join-Path $RepoRoot 'scripts/register-ocm-cluster.ps1') -Context $SpokeContext -ClusterName $SpokeName -HubContext $HubContext -ManagedBy ocm-demo
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'OCM registration failed.' }

Write-Host "`nManaged clusters visible to OCM on '$HubContext':" -ForegroundColor Green
& kubectl --context $HubContext get managedclusters
if ($LASTEXITCODE -ne 0) { throw 'Unable to list OCM ManagedClusters.' }

Write-Host "`nDemo cluster details and registration conditions:" -ForegroundColor Green
& kubectl --context $HubContext get managedcluster $SpokeName -o yaml
if ($LASTEXITCODE -ne 0) { throw "Unable to show ManagedCluster '$SpokeName'." }

Write-Host "`nThis demo installs OCM only; it does not install Flux or Kyverno on '$SpokeName'." -ForegroundColor Yellow
