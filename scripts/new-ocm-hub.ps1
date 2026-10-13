[CmdletBinding()]
param(
    [string]$Name = 'ocm-hub',
    [string]$K3sImage = 'rancher/k3s:v1.34.12-k3s1'
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('k3d', 'kubectl', 'clusteradm', 'helm')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found in PATH." }
}
$Context = "k3d-$Name"
$Existing = & k3d cluster list -o json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the k3d cluster inventory.' }
$Clusters = ConvertFrom-Json -InputObject ($Existing -join [Environment]::NewLine)
if (-not ($Clusters | Where-Object { $_.name -eq $Name })) {
    & k3d cluster create $Name --image $K3sImage --wait --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "Failed to create OCM hub cluster '$Name'." }
}
& kubectl --context $Context cluster-info *> $null
if ($LASTEXITCODE -ne 0) { throw "The hub context '$Context' is not reachable." }
$HubCrd = & kubectl --context $Context get crd clustermanagers.operator.open-cluster-management.io --ignore-not-found -o name
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect OCM on '$Context'." }
$HubExists = $false
if ($HubCrd) {
    $HubOutput = & kubectl --context $Context get clustermanager cluster-manager -o name
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect the OCM hub on '$Context'." }
    $HubExists = [bool]$HubOutput
}
if ($HubExists) {
    Write-Host "OCM is already initialized on '$Context'." -ForegroundColor Green
    return
}
Write-Host "Initializing Open Cluster Management on '$Context'..." -ForegroundColor Cyan
& clusteradm init --bundle-version v1.3.1 --wait --context $Context
if ($LASTEXITCODE -ne 0) {
    Write-Warning 'clusteradm init could not render its embedded chart; falling back to the official OCM Helm chart v1.3.1.'
    & helm repo add ocm https://open-cluster-management.io/helm-charts --force-update
    if ($LASTEXITCODE -ne 0) { throw 'Unable to add the official OCM Helm repository.' }
    & helm repo update ocm
    if ($LASTEXITCODE -ne 0) { throw 'Unable to update the official OCM Helm repository.' }
    & helm upgrade --install cluster-manager ocm/cluster-manager --version 1.3.1 --kube-context $Context --namespace open-cluster-management --create-namespace --set createBootstrapSA=true --set images.tag=v1.3.1 --wait --timeout 5m
    if ($LASTEXITCODE -ne 0) { throw "Unable to install the OCM cluster-manager chart on '$Context'." }
}
Write-Host "OCM hub is ready on '$Context'. Use it as HubContext when onboarding spokes." -ForegroundColor Green
