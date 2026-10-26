#Requires -Version 5.1
# ============================================
# Configuration
# ============================================
. "$PSScriptRoot\00-config.ps1"
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

# ============================================
# Orchestrator entry point (run elevated / SYSTEM)
# ============================================
try {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator or SYSTEM privileges required.'
    }
    if ($RemoteFolder -notmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$') { throw 'Invalid package folder name.' }

    # v0.2 supports a single active deployment per endpoint.
    $ActiveFile = Join-Path $EngineRoot 'active-package.txt'
    if (Test-Path -LiteralPath $ActiveFile -PathType Leaf) {
        $Previous = (Get-Content -LiteralPath $ActiveFile -Raw).Trim()
        if ($Previous -ne $RemoteFolder) {
            $OtherState = Join-Path (Join-Path $EngineRoot $Previous) 'deployment-state.json'
            if (Test-Path -LiteralPath $OtherState) {
                $OtherStatus = (Get-Content -LiteralPath $OtherState -Raw | ConvertFrom-Json).Status
                if ($OtherStatus -notin @('Completed','Failed')) { throw "Another package is active: $Previous" }
            }
        }
    }
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $Existing = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        if ($Existing.Status -eq 'Completed') { Write-Host 'Package already completed. To redeploy, follow reset instructions.'; exit 0 }
        if ($Existing.Status -eq 'Failed') { throw 'Previous deployment failed. Review logs and reset manually.' }
        if ($Existing.Status -eq 'Running') { Write-Host 'Deployment is already running. Check status script; no second start issued.'; exit 0 }
        if ($Existing.Status -eq 'WaitingForReboot') { Write-Host 'Deployment waiting for reboot. Check status script.'; exit 0 }
    }

    Import-Module (Join-Path $PSScriptRoot '02-package-download.psm1') -Force
    Invoke-PackageDownload
    $VerifyFile = Join-Path $PSScriptRoot '03-verify-package.ps1'
    & $PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $VerifyFile
    if ($LASTEXITCODE -ne 0) { throw "03-verify-package.ps1 failed with code $LASTEXITCODE" }

    New-Item -ItemType Directory -Path $EngineInstallDir -Force | Out-Null
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    # The engine and its configuration must survive agent process exit and reboots.
    foreach ($Name in @('00-config.ps1','00-manifest-helpers.ps1','06-deployment-engine.ps1','07-reboot-manager.ps1','08-deployment-status.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $Name) -Destination (Join-Path $EngineInstallDir $Name) -Force
    }
    $OverrideFile = Join-Path $PSScriptRoot '00-local-settings.ps1'
    $StagedOverride = Join-Path $EngineInstallDir '00-local-settings.ps1'
    if (Test-Path -LiteralPath $OverrideFile -PathType Leaf) {
        Copy-Item -LiteralPath $OverrideFile -Destination $StagedOverride -Force
    } elseif (Test-Path -LiteralPath $StagedOverride -PathType Leaf) {
        Remove-Item -LiteralPath $StagedOverride -Force
    }
    Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $StateDir 'manifest.txt') -Force
    Set-Content -LiteralPath $ActiveFile -Value $RemoteFolder -Encoding ASCII

    $EngineFile = Join-Path $EngineInstallDir '06-deployment-engine.ps1'
    & $PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $EngineFile
    if ($LASTEXITCODE -ne 0) { throw "Deployment engine returned code $LASTEXITCODE" }
    Write-Host 'Deployment accepted. Check deployment-state.json for Completed/WaitingForReboot status.'
    exit 0
} catch {
    Write-Error "Deployment start failed: $($_.Exception.Message)"
    exit 1
}
