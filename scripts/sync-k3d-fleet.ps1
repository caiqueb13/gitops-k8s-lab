[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[^\s]+$')]
    [string]$GitUrl,

    [string]$ContextPattern = '^k3d-',

    [string]$HubContext = 'k3d-ocm-hub',

    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$GitSecretName
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('k3d', 'kubectl', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' was not found in PATH."
    }
}

$ClustersJson = & k3d cluster list -o json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the active k3d cluster inventory.' }
$Clusters = ConvertFrom-Json -InputObject ($ClustersJson -join [Environment]::NewLine)
$Targets = @()
foreach ($Cluster in $Clusters) {
    if (-not $Cluster -or -not $Cluster.name) { continue }
    $ContextName = "k3d-$($Cluster.name)"
    if ($ContextName -match $ContextPattern) { $Targets += $ContextName }
}
if ($Targets.Count -eq 0) {
    Write-Host "No contexts matched '$ContextPattern'." -ForegroundColor Yellow
}

$Failures = [System.Collections.Generic.List[string]]::new()
foreach ($Context in $Targets) {
    $Name = $Context -replace '^k3d-', ''
    Write-Host "`n=== $Context ===" -ForegroundColor Cyan
    try {
        & (Join-Path $PSScriptRoot 'bootstrap-context.ps1') -Name $Name -Context $Context -GitUrl $GitUrl -GitSecretName $GitSecretName
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Bootstrap process failed with exit code $LASTEXITCODE." }
        & (Join-Path $PSScriptRoot 'register-ocm-cluster.ps1') -Context $Context -ClusterName $Name -HubContext $HubContext -ManagedBy k3d-fleet
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "OCM registration process failed with exit code $LASTEXITCODE." }
    }
    catch {
        $Failures.Add("$Context`: $($_.Exception.Message)")
        Write-Warning $Failures[$Failures.Count - 1]
    }
}

$ActiveNames = @($Targets | ForEach-Object { $_ -replace '^k3d-', '' })
$ManagedJson = & kubectl --context $HubContext get managedclusters -l lab.gitops/managed-by=k3d-fleet -o json
if ($LASTEXITCODE -ne 0) { throw "Unable to read k3d-fleet entries from OCM hub '$HubContext'." }
$Managed = ConvertFrom-Json -InputObject ($ManagedJson -join [Environment]::NewLine)
foreach ($Entry in $Managed.items) {
    if ($Entry.metadata.name -notin $ActiveNames) {
        Write-Host "Removing deleted k3d cluster '$($Entry.metadata.name)' from OCM inventory..." -ForegroundColor Yellow
        & kubectl --context $HubContext delete managedcluster $Entry.metadata.name --wait=false
        if ($LASTEXITCODE -ne 0) { throw "Unable to remove stale OCM entry '$($Entry.metadata.name)'." }
    }
}
if ($Failures.Count -gt 0) {
    throw ("Fleet sync finished with {0} failure(s):`n{1}" -f $Failures.Count, ($Failures -join "`n"))
}
Write-Host "Fleet scan complete: $($Targets.Count) active k3d cluster(s) considered." -ForegroundColor Green
