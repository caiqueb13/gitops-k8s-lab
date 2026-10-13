[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[^\s]+$')]
    [string]$GitUrl,

    [string]$Context = "k3d-$Name",

    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$GitSecretName
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TemplatePath = Join-Path $RepoRoot 'bootstrap/flux-sync.yaml.template'

function Invoke-Checked {
    param([string]$FilePath, [string[]]$Arguments)
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed ($LASTEXITCODE): $FilePath $($Arguments -join ' ')"
    }
}

foreach ($tool in @('kubectl', 'flux')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$tool' was not found in PATH."
    }
}
if (-not (Test-Path -LiteralPath $TemplatePath)) {
    throw "Bootstrap template not found: $TemplatePath"
}

Write-Host "Checking Kubernetes context '$Context'..." -ForegroundColor Cyan
if ($env:OS -eq 'Windows_NT' -and $Context -like 'k3d-*') {
    $ContextConfigJson = & kubectl config view --minify --context $Context -o json
    if ($LASTEXITCODE -ne 0) { throw "Unable to read kubeconfig context '$Context'." }
    $ContextConfig = $ContextConfigJson | ConvertFrom-Json
    $ClusterEntry = $ContextConfig.clusters | Select-Object -First 1
    if ($ClusterEntry -and ([uri]$ClusterEntry.cluster.server).Host -eq 'host.docker.internal') {
        $ApiPort = ([uri]$ClusterEntry.cluster.server).Port
        $LocalServer = "https://127.0.0.1:$ApiPort"
        Write-Host "Using localhost for the k3d API endpoint: $LocalServer" -ForegroundColor Cyan
        Invoke-Checked -FilePath 'kubectl' -Arguments @('config', 'set-cluster', $ClusterEntry.name, "--server=$LocalServer")
    }
}
Invoke-Checked -FilePath 'kubectl' -Arguments @('--context', $Context, 'cluster-info')
$Controllers = & kubectl --context $Context -n flux-system get deployment source-controller kustomize-controller helm-controller notification-controller --ignore-not-found -o name
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect Flux controllers in '$Context'." }
$Controllers = @($Controllers | Where-Object { $_ })
if ($Controllers.Count -eq 0) {
    Invoke-Checked -FilePath 'flux' -Arguments @('check', '--pre', '--context', $Context)
    Write-Host "Installing or completing Flux installation in '$Context'..." -ForegroundColor Cyan
    Invoke-Checked -FilePath 'flux' -Arguments @('install', '--context', $Context)
}
elseif ($Controllers.Count -lt 4) {
    throw "Flux is only partially installed in '$Context' ($($Controllers.Count)/4 controllers). Repair it manually before onboarding; refusing to overwrite an unknown installation."
}
else {
    Write-Host "Flux controllers already exist in '$Context'; checking their health..." -ForegroundColor Cyan
    Invoke-Checked -FilePath 'flux' -Arguments @('check', '--context', $Context)
}
if ($GitSecretName) {
    & kubectl --context $Context -n flux-system get secret $GitSecretName *> $null
    if ($LASTEXITCODE -ne 0) { throw "Git authentication Secret '$GitSecretName' must already exist in namespace flux-system; the onboarding script never accepts or stores secret values." }
}

$ExistingGitJson = & kubectl --context $Context -n flux-system get gitrepository lab-config --ignore-not-found -o json
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect GitRepository/lab-config in '$Context'." }
if ($ExistingGitJson) {
    $ExistingGit = $ExistingGitJson | ConvertFrom-Json
    $ExistingSecret = [string]$ExistingGit.spec.secretRef.name
    if ($ExistingGit.spec.url -ne $GitUrl -or $ExistingSecret -ne [string]$GitSecretName) {
        throw "GitRepository/lab-config already exists in '$Context' with a different URL or authentication Secret. Resolve the ownership conflict before onboarding."
    }
}
$ExistingKustomizationJson = & kubectl --context $Context -n flux-system get kustomization kyverno --ignore-not-found -o json
if ($LASTEXITCODE -ne 0) { throw "Unable to inspect Kustomization/kyverno in '$Context'." }
if ($ExistingKustomizationJson) {
    $ExistingKustomization = $ExistingKustomizationJson | ConvertFrom-Json
    if ($ExistingKustomization.spec.path -ne './apps/kyverno' -or $ExistingKustomization.spec.sourceRef.name -ne 'lab-config') {
        throw "Kustomization/kyverno already exists in '$Context' with a different path or source. Resolve the ownership conflict before onboarding."
    }
}

$RenderedPath = Join-Path ([System.IO.Path]::GetTempPath()) ("flux-sync-{0}-{1}.yaml" -f $Name, [guid]::NewGuid().ToString('N'))
try {
    $SecretRef = if ($GitSecretName) { "  secretRef:`n    name: $GitSecretName" } else { '' }
    $Rendered = (Get-Content -LiteralPath $TemplatePath -Raw).Replace('__GIT_URL__', $GitUrl).Replace('__GIT_SECRET_REF__', $SecretRef)
    if ($Rendered.Contains('__GIT_URL__') -or $Rendered.Contains('__GIT_SECRET_REF__')) { throw 'The Git URL template was not fully rendered.' }
    [System.IO.File]::WriteAllText($RenderedPath, $Rendered, [System.Text.UTF8Encoding]::new($false))

    Write-Host "Configuring GitOps sync from $GitUrl..." -ForegroundColor Cyan
    Invoke-Checked -FilePath 'kubectl' -Arguments @('--context', $Context, 'apply', '-f', $RenderedPath)

    Write-Host 'Waiting for Kyverno reconciliation...' -ForegroundColor Cyan
    Invoke-Checked -FilePath 'kubectl' -Arguments @('--context', $Context, '-n', 'flux-system', 'wait', '--for=condition=Ready', 'kustomization/kyverno', '--timeout=5m')
    Invoke-Checked -FilePath 'kubectl' -Arguments @('--context', $Context, '-n', 'flux-system', 'wait', '--for=condition=Ready', 'helmrelease/kyverno', '--timeout=10m')
}
finally {
    Remove-Item -LiteralPath $RenderedPath -Force -ErrorAction SilentlyContinue
}

Write-Host "Cluster '$Context' is bootstrapped. Verify with: kubectl --context $Context get pods -n kyverno" -ForegroundColor Green
