[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$HubName = 'ocm-hub',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$FluxClusterName = 'ocm-flux-demo',
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$PlainClusterName = 'ocm-plain-demo',
    [string]$GitUrl = 'https://github.com/caiqueb13/gitops-k8s-lab.git',
    [string]$K3sImage = 'rancher/k3s:v1.34.12-k3s1'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('k3d', 'kubectl', 'clusteradm', 'docker', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found in PATH." }
}
if ($FluxClusterName -eq $PlainClusterName -or $FluxClusterName -eq $HubName -or $PlainClusterName -eq $HubName) {
    throw 'Hub, Flux demo, and plain demo cluster names must be different.'
}

$HubContext = "k3d-$HubName"
$FluxContext = "k3d-$FluxClusterName"
$PlainContext = "k3d-$PlainClusterName"
$SharedNetwork = "k3d-$HubName"

function Ensure-Spoke {
    param([string]$Name)
    $clustersJson = & k3d cluster list -o json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read the k3d cluster inventory.' }
    $clusters = ConvertFrom-Json -InputObject ($clustersJson -join [Environment]::NewLine)
    if (-not ($clusters | Where-Object { $_.name -eq $Name })) {
        Write-Host "Creating '$Name' on shared Docker network '$SharedNetwork'..." -ForegroundColor Cyan
        & k3d cluster create $Name --image $K3sImage --network $SharedNetwork --wait --timeout 5m
        if ($LASTEXITCODE -ne 0) { throw "Failed to create demo cluster '$Name'." }
    }
    $context = "k3d-$Name"
    & kubectl --context $context cluster-info *> $null
    if ($LASTEXITCODE -ne 0) { throw "Cluster context '$context' is not reachable." }
    $container = "k3d-$Name-server-0"
    $networksJson = & docker inspect $container --format '{{json .NetworkSettings.Networks}}'
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect demo node '$container'." }
    $networks = $networksJson | ConvertFrom-Json
    if ($SharedNetwork -notin @($networks.PSObject.Properties | ForEach-Object { $_.Name })) {
        throw "Cluster '$Name' is not attached to '$SharedNetwork'. Delete only that demo cluster and rerun the script."
    }
}

Write-Host 'Preparing the OCM hub...' -ForegroundColor Cyan
& (Join-Path $RepoRoot 'scripts/new-ocm-hub.ps1') -Name $HubName -K3sImage $K3sImage
& kubectl --context $HubContext cluster-info *> $null
if ($LASTEXITCODE -ne 0) { throw "Hub context '$HubContext' is not reachable." }

Ensure-Spoke -Name $FluxClusterName
Ensure-Spoke -Name $PlainClusterName

Write-Host "Installing Flux and reconciling Kyverno from $GitUrl on '$FluxClusterName'..." -ForegroundColor Cyan
& (Join-Path $RepoRoot 'scripts/bootstrap-context.ps1') -Name $FluxClusterName -Context $FluxContext -GitUrl $GitUrl

Write-Host 'Registering both spokes with OCM...' -ForegroundColor Cyan
& (Join-Path $RepoRoot 'scripts/register-ocm-cluster.ps1') -Context $FluxContext -ClusterName $FluxClusterName -HubContext $HubContext -ManagedBy ocm-demo
& (Join-Path $RepoRoot 'scripts/register-ocm-cluster.ps1') -Context $PlainContext -ClusterName $PlainClusterName -HubContext $HubContext -ManagedBy ocm-demo

Write-Host "`nManaged clusters visible to OCM on '$HubContext':" -ForegroundColor Green
& kubectl --context $HubContext get managedclusters
Write-Host "`nManagedCluster details:" -ForegroundColor Green
& kubectl --context $HubContext get managedcluster $FluxClusterName $PlainClusterName -o wide

Write-Host "`nFlux and Kyverno on '$FluxClusterName' (expected present and healthy):" -ForegroundColor Green
& flux get all -A --context $FluxContext
& kubectl --context $FluxContext -n flux-system get helmrelease kyverno

Write-Host "`nFlux and Kyverno on '$PlainClusterName' (expected absent):" -ForegroundColor Yellow
& kubectl --context $PlainContext get namespaces flux-system kyverno --ignore-not-found
Write-Host "`nOCM tracks both clusters; only '$FluxClusterName' receives Flux and Kyverno." -ForegroundColor Cyan
