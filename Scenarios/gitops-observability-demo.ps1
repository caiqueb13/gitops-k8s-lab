[CmdletBinding()]
param(
    [string]$GitUrl = 'https://github.com/caiqueb13/gitops-k8s-lab.git',
    [string]$FluxClusterName = 'demo-gitops',
    [string]$PlainClusterName = 'demo-plain',
    [string]$K3sImage = 'rancher/k3s:v1.34.12-k3s1',
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
foreach ($tool in @('k3d', 'kubectl', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found in PATH." }
}
if ($FluxClusterName -eq $PlainClusterName) { throw 'Demo cluster names must be different.' }

if ($Cleanup) {
    foreach ($Name in @($FluxClusterName, $PlainClusterName)) {
        $Inventory = & k3d cluster list -o json | ConvertFrom-Json
        if ($Inventory.name -contains $Name) { & k3d cluster delete $Name; if ($LASTEXITCODE -ne 0) { throw "Unable to delete '$Name'." } }
    }
    return
}

foreach ($Name in @($FluxClusterName, $PlainClusterName)) {
    $InventoryJson = & k3d cluster list -o json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read k3d cluster inventory.' }
    $Inventory = ConvertFrom-Json -InputObject ($InventoryJson -join [Environment]::NewLine)
    if (-not ($Inventory | Where-Object { $_.name -eq $Name })) {
        & k3d cluster create $Name --image $K3sImage --wait --timeout 5m
        if ($LASTEXITCODE -ne 0) { throw "Unable to create '$Name'." }
    }
    & kubectl --context "k3d-$Name" cluster-info *> $null
    if ($LASTEXITCODE -ne 0) { throw "Cluster context 'k3d-$Name' is unavailable." }
}

& (Join-Path $RepoRoot 'scripts/bootstrap-context.ps1') -Name $FluxClusterName -Context "k3d-$FluxClusterName" -GitUrl $GitUrl
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Unable to bootstrap Flux demo cluster '$FluxClusterName'." }
Write-Host "Demo ready. Start the dashboard and compare k3d-$FluxClusterName with k3d-$PlainClusterName." -ForegroundColor Green
Write-Host "Cleanup only these demo clusters with: ./Scenarios/gitops-observability-demo.ps1 -Cleanup" -ForegroundColor Yellow
