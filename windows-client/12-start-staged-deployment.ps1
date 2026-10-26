#Requires -Version 5.1
# ============================================
# Configuration
# ============================================
. "$PSScriptRoot\00-config.ps1"
$PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

# ============================================
# Start a pre-downloaded package (background worker only)
# ============================================
try {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator or SYSTEM privileges required.'
    }
    if ($RemoteFolder -notmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$') { throw 'Invalid package folder name.' }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw 'Missing staged manifest.txt.' }
    if (-not (Test-Path -LiteralPath (Join-Path $DestinationFolder 'deployment.json') -PathType Leaf)) {
        throw 'Missing staged deployment.json.'
    }
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
        if ($Existing.Status -eq 'Completed') { Write-Host 'Package already completed.'; exit 0 }
        if ($Existing.Status -eq 'Failed') { throw 'Previous deployment failed; review logs before retrying.' }
        if ($Existing.Status -in @('Running','WaitingForReboot')) {
            Write-Host "Deployment already in progress: $($Existing.Status)"; exit 0
        }
    }

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
    Write-Error "Staged deployment start failed: $($_.Exception.Message)"
    exit 1
}
