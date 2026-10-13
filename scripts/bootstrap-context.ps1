[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[^\s]+$')]
    [string]$GitUrl,

    [string]$Context = "k3d-$Name"
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
Invoke-Checked -FilePath 'kubectl' -Arguments @('--context', $Context, 'cluster-info')
Invoke-Checked -FilePath 'flux' -Arguments @('check', '--pre', '--context', $Context)

Write-Host "Installing or reconciling Flux in '$Context'..." -ForegroundColor Cyan
Invoke-Checked -FilePath 'flux' -Arguments @('install', '--context', $Context)

$RenderedPath = Join-Path ([System.IO.Path]::GetTempPath()) ("flux-sync-{0}-{1}.yaml" -f $Name, [guid]::NewGuid().ToString('N'))
try {
    $Rendered = (Get-Content -LiteralPath $TemplatePath -Raw).Replace('__GIT_URL__', $GitUrl)
    if ($Rendered.Contains('__GIT_URL__')) { throw 'The Git URL template was not fully rendered.' }
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
