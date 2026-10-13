[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Context,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')][string]$ClusterName,
    [string]$HubContext = 'k3d-ocm-hub',
    [ValidateSet('k3d-fleet', 'explicit', 'ocm-demo')][string]$ManagedBy = 'explicit'
)

$ErrorActionPreference = 'Stop'
foreach ($tool in @('kubectl', 'clusteradm', 'helm')) {
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
    $TokenMatch = [regex]::Match($TokenText, '(?:^|\s)token=(\S+)')
    if (-not $TokenMatch.Success) { $TokenMatch = [regex]::Match($TokenText, '--hub-token(?:=|\s+)(?:"([^"]+)"|(\S+))') }
    if (-not $TokenMatch.Success) { throw 'Could not parse the OCM bootstrap token from clusteradm output.' }
    $Token = if ($TokenMatch.Groups[1].Success) { $TokenMatch.Groups[1].Value } else { $TokenMatch.Groups[2].Value }

    $KlusterletCrd = & kubectl --context $Context get crd klusterlets.operator.open-cluster-management.io --ignore-not-found -o name
    if ($LASTEXITCODE -ne 0) { throw "Unable to inspect klusterlet API on '$Context'." }
    $ExistingKlusterlet = @()
    if ($KlusterletCrd) {
        $ExistingKlusterlet = & kubectl --context $Context get klusterlet klusterlet --ignore-not-found -o name
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect klusterlet on '$Context'." }
    }
    if (-not $ExistingKlusterlet) {
        $ApiMatch = [regex]::Match($TokenText, '--hub-apiserver(?:=|\s+)(?:"([^"]+)"|(\S+))')
        if (-not $ApiMatch.Success) { throw 'Could not parse the OCM API endpoint from clusteradm output.' }
        $Api = if ($ApiMatch.Groups[1].Success) { $ApiMatch.Groups[1].Value } else { $ApiMatch.Groups[2].Value }
        & clusteradm join --hub-token $Token --hub-apiserver $Api --bundle-version v1.3.1 --wait --cluster-name $ClusterName --force-internal-endpoint-lookup --context $Context
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'clusteradm join could not render its embedded chart; installing the official OCM klusterlet chart v1.3.1.'
            & helm repo add ocm https://open-cluster-management.io/helm-charts --force-update
            if ($LASTEXITCODE -ne 0) { throw 'Unable to add the official OCM Helm repository.' }
            & helm repo update ocm
            if ($LASTEXITCODE -ne 0) { throw 'Unable to update the official OCM Helm repository.' }

            $HubConfigJson = & kubectl --context $HubContext config view --raw --flatten --minify -o json
            if ($LASTEXITCODE -ne 0) { throw "Unable to read the hub CA from context '$HubContext'." }
            $HubConfig = $HubConfigJson | ConvertFrom-Json
            $CaData = $HubConfig.clusters[0].cluster.'certificate-authority-data'
            if (-not $CaData) { throw 'The OCM hub kubeconfig has no embedded CA certificate.' }
            $HubClusterName = $HubContext -replace '^k3d-', ''
            $BootstrapPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ocm-bootstrap-{0}-{1}.yaml" -f $ClusterName, [guid]::NewGuid().ToString('N'))
            try {
                $BootstrapConfig = @"
apiVersion: v1
kind: Config
clusters:
- name: hub
  cluster:
    server: https://k3d-$HubClusterName-server-0:6443
    certificate-authority-data: $CaData
users:
- name: bootstrap
  user:
    token: $Token
contexts:
- name: bootstrap
  context:
    cluster: hub
    user: bootstrap
current-context: bootstrap
"@
                [System.IO.File]::WriteAllText($BootstrapPath, $BootstrapConfig, [System.Text.UTF8Encoding]::new($false))
                $SetFile = 'bootstrapHubKubeConfig=' + $BootstrapPath.Replace('\', '/')
                & helm upgrade --install klusterlet ocm/klusterlet --version 1.3.1 --kube-context $Context --namespace open-cluster-management --create-namespace --set images.tag=v1.3.1 --set klusterlet.mode=Default --set "klusterlet.clusterName=$ClusterName" --set klusterlet.namespace=open-cluster-management-agent --set-file $SetFile --wait --timeout 5m
                if ($LASTEXITCODE -ne 0) { throw "Unable to install OCM klusterlet on '$Context'." }
            }
            finally { Remove-Item -LiteralPath $BootstrapPath -Force -ErrorAction SilentlyContinue }
        }
    }
    $RegistrationRequestReady = $false
    for ($Attempt = 0; $Attempt -lt 36; $Attempt++) {
        $ManagedClusterRequest = & kubectl --context $HubContext get managedcluster $ClusterName --ignore-not-found -o name
        if ($LASTEXITCODE -ne 0) { throw "Unable to inspect pending OCM registration for '$ClusterName'." }
        $CsrJson = & kubectl --context $HubContext get csr -o json
        if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect OCM certificate signing requests.' }
        $CsrList = $CsrJson | ConvertFrom-Json
        $CsrRequest = $CsrList.items | Where-Object { $_.metadata.name -like "$ClusterName-*" } | Select-Object -First 1
        if ($ManagedClusterRequest -and $CsrRequest) { $RegistrationRequestReady = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $RegistrationRequestReady) { throw "Timed out waiting for OCM registration request from '$ClusterName'." }
    & clusteradm accept --clusters $ClusterName --context $HubContext
    if ($LASTEXITCODE -ne 0) { throw "OCM registration approval failed for '$ClusterName'." }
}

& kubectl --context $HubContext label managedcluster $ClusterName "lab.gitops/managed-by=$ManagedBy" --overwrite
if ($LASTEXITCODE -ne 0) { throw "Unable to mark OCM cluster '$ClusterName' as lab-managed." }
& kubectl --context $HubContext annotate managedcluster $ClusterName "lab.gitops/context=$Context" --overwrite
if ($LASTEXITCODE -ne 0) { throw "Unable to record context for OCM cluster '$ClusterName'." }
Write-Host "Registered '$ClusterName' ($Context) in OCM hub '$HubContext'." -ForegroundColor Green
