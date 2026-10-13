[CmdletBinding()]
param(
    [string]$HubContext = 'k3d-ocm-hub',
    [ValidateSet('Table', 'Json', 'Csv')][string]$Format = 'Table',
    [switch]$FailOnUnhealthy
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('kubectl', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required command '$tool' was not found in PATH." }
}
$InventoryJson = & kubectl --context $HubContext get managedclusters -l lab.gitops/managed-by -o json
if ($LASTEXITCODE -ne 0) { throw "Unable to read OCM inventory from '$HubContext'." }
$Inventory = ConvertFrom-Json -InputObject ($InventoryJson -join [Environment]::NewLine)
$Results = [System.Collections.Generic.List[object]]::new()

function Test-ReadyCondition {
    param([string]$Context, [string]$Resource, [string]$Namespace)
    $KubectlArgs = @('--context', $Context, '-n', $Namespace, 'get', $Resource, '-o', 'json')
    $Json = & kubectl @KubectlArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $Json) { return $false }
    $Object = $Json | ConvertFrom-Json
    return [bool]($Object.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' })
}

foreach ($Cluster in $Inventory.items) {
    $Name = $Cluster.metadata.name
    $Context = $Cluster.metadata.annotations.'lab.gitops/context'
    $FluxState = 'NotReady'
    $KyvernoState = 'NotReady'
    $Details = [System.Collections.Generic.List[string]]::new()
    if (-not $Context) {
        $Details.Add('missing context annotation')
    }
    else {
        & kubectl --context $Context cluster-info *> $null
        if ($LASTEXITCODE -ne 0) {
            $Details.Add('context unavailable')
        }
        else {
            $FluxCheck = & flux check --context $Context 2>&1
            $FluxOk = ($LASTEXITCODE -eq 0)
            $DeploymentsJson = & kubectl --context $Context -n flux-system get deployments source-controller kustomize-controller helm-controller notification-controller -o json 2>$null
            $DeploymentsOk = ($LASTEXITCODE -eq 0 -and $DeploymentsJson)
            if ($DeploymentsOk) {
                $Deployments = ConvertFrom-Json -InputObject ($DeploymentsJson -join [Environment]::NewLine)
                foreach ($Deployment in $Deployments.items) {
                    $Expected = if ($null -eq $Deployment.spec.replicas) { 1 } else { [int]$Deployment.spec.replicas }
                    if ([int]$Deployment.status.availableReplicas -lt $Expected) { $DeploymentsOk = $false }
                }
            }
            $SourcesOk = (Test-ReadyCondition -Context $Context -Resource 'gitrepository/lab-config' -Namespace 'flux-system') -and
                (Test-ReadyCondition -Context $Context -Resource 'kustomization/kyverno' -Namespace 'flux-system')
            if ($FluxOk -and $DeploymentsOk -and $SourcesOk) { $FluxState = 'Ready' }
            else {
                if (-not $FluxOk) { $Details.Add('flux check failed') }
                if (-not $DeploymentsOk) { $Details.Add('Flux controller deployment unavailable') }
                if (-not $SourcesOk) { $Details.Add('GitRepository or Kustomization not Ready') }
            }

            $ReleaseOk = Test-ReadyCondition -Context $Context -Resource 'helmrelease/kyverno' -Namespace 'flux-system'
            $PodsJson = & kubectl --context $Context -n kyverno get pods -o json 2>$null
            $PodsOk = ($LASTEXITCODE -eq 0 -and $PodsJson)
            if ($PodsOk) {
                $Pods = ConvertFrom-Json -InputObject ($PodsJson -join [Environment]::NewLine)
                $PodsOk = ($Pods.items.Count -gt 0) -and (@($Pods.items | Where-Object { $_.status.phase -ne 'Running' }).Count -eq 0)
            }
            if ($ReleaseOk -and $PodsOk) { $KyvernoState = 'Ready' }
            else { $Details.Add('Kyverno HelmRelease or pods not Ready') }
        }
    }

    $Timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    & kubectl --context $HubContext annotate managedcluster $Name "lab.gitops/flux-status=$FluxState" "lab.gitops/kyverno-status=$KyvernoState" "lab.gitops/last-audited=$Timestamp" --overwrite *> $null
    if ($LASTEXITCODE -ne 0) { $Details.Add('could not update OCM audit annotations') }
    $Results.Add([pscustomobject]@{
        Cluster = $Name
        Context = $Context
        OCMAvailable = [string](($Cluster.status.conditions | Where-Object { $_.type -eq 'ManagedClusterConditionAvailable' } | Select-Object -First 1).status)
        Flux = $FluxState
        Kyverno = $KyvernoState
        Details = ($Details -join '; ')
        AuditedAtUtc = $Timestamp
    })
}

switch ($Format) {
    'Json' { $Results | ConvertTo-Json -Depth 5 }
    'Csv' { $Results | ConvertTo-Csv -NoTypeInformation }
    default { $Results | Format-Table -AutoSize }
}
if ($FailOnUnhealthy -and @($Results | Where-Object { $_.Flux -ne 'Ready' -or $_.Kyverno -ne 'Ready' -or $_.OCMAvailable -ne 'True' }).Count -gt 0) { exit 2 }
