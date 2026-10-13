[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[^\s]+$')]
    [string]$GitUrl,

    [ValidateRange(15, 3600)]
    [int]$IntervalSeconds = 60,

    [string]$ContextPattern = '^k3d-',

    [string]$HubContext = 'k3d-ocm-hub',

    [ValidatePattern('^[a-z0-9]([-a-z0-9]*[a-z0-9])?$')]
    [string]$GitSecretName
)

$ErrorActionPreference = 'Stop'
Write-Host "Watching local k3d clusters every $IntervalSeconds seconds. Press Ctrl+C to stop." -ForegroundColor Cyan
while ($true) {
    try {
        & (Join-Path $PSScriptRoot 'sync-k3d-fleet.ps1') -GitUrl $GitUrl -ContextPattern $ContextPattern -HubContext $HubContext -GitSecretName $GitSecretName
    }
    catch {
        Write-Warning "Fleet reconciliation failed: $($_.Exception.Message). Retrying after the interval."
    }
    Start-Sleep -Seconds $IntervalSeconds
}
