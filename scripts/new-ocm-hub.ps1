[CmdletBinding()]
param(
    [string]$Name = 'ocm-hub',
    [string]$K3sImage = 'rancher/k3s:v1.34.12-k3s1'
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('k3d', 'kubectl', 'clusteradm')) {
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
$Hub = & kubectl --context $Context get clustermanager cluster-manager -o name 2>$null
if ($LASTEXITCODE -eq 0 -and $Hub) {
    Write-Host "OCM is already initialized on '$Context'." -ForegroundColor Green
    return
}
Write-Host "Initializing Open Cluster Management on '$Context'..." -ForegroundColor Cyan
& clusteradm init --wait --context $Context
if ($LASTEXITCODE -ne 0) { throw "clusteradm init failed on '$Context'." }
Write-Host "OCM hub is ready on '$Context'. Use it as HubContext when onboarding spokes." -ForegroundColor Green
