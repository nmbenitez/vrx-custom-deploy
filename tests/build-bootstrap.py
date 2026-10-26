#!/usr/bin/env python3
"""Regenerate self-contained single-file vRx script from modular PowerShell sources."""
from pathlib import Path
import base64
import io
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / 'windows-client'
REQUIRED = ('02-package-download.psm1',)
for name in REQUIRED:
    if not (CLIENT / name).is_file():
        raise SystemExit(f'Missing required source: {name}')
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted(list(CLIENT.glob('*.ps1')) + list(CLIENT.glob('*.psm1'))):
        if path.name != '09-vrx-bootstrap.ps1':
            archive.write(path, arcname=path.name)
encoded = base64.b64encode(buf.getvalue()).decode('ascii')
wrapped = '\n'.join(encoded[i:i+100] for i in range(0, len(encoded), 100))
bootstrap = r'''#Requires -Version 5.1
# ============================================
# Operator settings in the single action stored in vRx
# ============================================
$Server = ""                          # Set the Ubuntu address once in vRx
$RemoteFolder = ""                    # Set the published package for this launch
$BootstrapMode = "DownloadOnly"       # DownloadOnly first, Deploy later

# Internal paths. Download and retry defaults live in 00-config.ps1.
$EngineRoot = "C:\ProgramData\vRxDeploy"
$BootstrapRoot = "C:\ProgramData\vRxDeploy\bootstrap-v024"

# ============================================
# Queue persistent download or installation; return immediately to vRx
# ============================================
$ErrorActionPreference = "Stop"
$BootstrapMutex = $null
$HasBootstrapMutex = $false
$ReceiptCreatedThisRun = $false
try {
    if ($Server -notmatch '^[A-Za-z0-9.:-]+$') { throw 'Set a valid $Server in the vRx script.' }
    if ($RemoteFolder -notmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$') { throw 'Set $RemoteFolder to a published package name in the vRx script.' }
    if ($BootstrapMode -notin @('DownloadOnly','Deploy')) { throw 'Invalid bootstrap mode.' }

    # Prevent overlapping bootstrap executions and destructive redeployment of a live package.
    $BootstrapMutex = New-Object System.Threading.Mutex($false, 'Global\vRxDeploymentBootstrap')
    $HasBootstrapMutex = $BootstrapMutex.WaitOne(0)
    if (-not $HasBootstrapMutex) { throw 'A bootstrap execution is already in progress.' }

    $StateDir = Join-Path $EngineRoot $RemoteFolder
    $StatePath = Join-Path $StateDir 'deployment-state.json'
    $ReceiptPath = Join-Path $StateDir 'launch-receipt.json'
    $ModePath = Join-Path $StateDir 'requested-mode.txt'
    $TaskName = 'vRxDeploy-Launch'

    $ActiveFile = Join-Path $EngineRoot 'active-package.txt'
    if (Test-Path -LiteralPath $ActiveFile -PathType Leaf) {
        $ActivePackage = (Get-Content -LiteralPath $ActiveFile -Raw).Trim()
        if ($ActivePackage -ne $RemoteFolder) {
            $OtherStatePath = Join-Path (Join-Path $EngineRoot $ActivePackage) 'deployment-state.json'
            if (Test-Path -LiteralPath $OtherStatePath -PathType Leaf) {
                $OtherStatus = (Get-Content -LiteralPath $OtherStatePath -Raw | ConvertFrom-Json).Status
                if ($OtherStatus -notin @('Completed','Failed')) { throw "Another deployment is active: $ActivePackage" }
            } else {
                $OtherReceiptPath = Join-Path (Join-Path $EngineRoot $ActivePackage) 'launch-receipt.json'
                if (Test-Path -LiteralPath $OtherReceiptPath -PathType Leaf) {
                    $OtherReceipt = Get-Content -LiteralPath $OtherReceiptPath -Raw | ConvertFrom-Json
                    if ($OtherReceipt.Status -ne 'Failed') { throw "Another package is queued: $ActivePackage" }
                }
            }
        }
    }
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $Existing = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Existing.Status -eq 'Completed') { Write-Host "ALREADY_COMPLETED: $RemoteFolder"; exit 0 }
        if ($Existing.Status -eq 'Failed') { throw "Previous deployment failed: $RemoteFolder. Investigate before resetting state." }
        if ($Existing.Status -in @('Running','WaitingForReboot')) {
            Write-Host "ALREADY_ACTIVE: $RemoteFolder ($($Existing.Status)). No duplicate launch issued."
            exit 0
        }
    }
    if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) {
        $ExistingReceipt = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ExistingReceipt.Status -eq 'Failed') { throw "Previous launch failed: $RemoteFolder. Investigate before resetting state." }
        if ($ExistingReceipt.Package -ne $RemoteFolder) { throw 'Launch receipt belongs to a different package.' }
        if ($ExistingReceipt.Server -and $ExistingReceipt.Server -ne $Server) { throw 'The staged package belongs to a different server.' }
        $ExistingMode = if (Test-Path -LiteralPath $ModePath -PathType Leaf) {
            (Get-Content -LiteralPath $ModePath -Raw -Encoding ASCII).Trim()
        } elseif ($ExistingReceipt.RequestedMode) { [string]$ExistingReceipt.RequestedMode } else { 'Deploy' }
        if ($ExistingMode -notin @('DownloadOnly','Deploy')) { throw "Invalid saved bootstrap mode: $ExistingMode" }
        if ($BootstrapMode -eq 'DownloadOnly' -or $ExistingMode -eq 'Deploy') {
            Write-Host "ALREADY_QUEUED: $RemoteFolder ($ExistingMode; $($ExistingReceipt.Status))."
            exit 0
        }
        $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $ExistingTask) { throw "Launch task is missing: $TaskName" }
        if (-not (Test-Path -LiteralPath (Join-Path $BootstrapRoot 'scripts\11-deployment-launch-worker.ps1') -PathType Leaf)) {
            throw 'Staged launch worker is missing.'
        }
        Set-Content -LiteralPath "$ModePath.tmp" -Value 'Deploy' -Encoding ASCII
        Move-Item -LiteralPath "$ModePath.tmp" -Destination $ModePath -Force
        try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
        catch { Write-Warning "Immediate launch failed; startup/periodic trigger remains registered: $($_.Exception.Message)" }
        Write-Host "DEPLOY_QUEUED: $RemoteFolder. Verified files will be reused."
        exit 0
    }

    # Fail safely if a previous start task is still running (single package supported).
    $PriorTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $PriorTask -and $PriorTask.State -eq 'Running') {
        throw "Deployment launch task is already running: $TaskName"
    }

    New-Item -ItemType Directory -Path $BootstrapRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $ZipPath = Join-Path $BootstrapRoot 'client-scripts.zip'
    $Extracted = Join-Path $BootstrapRoot 'scripts'
    if (Test-Path -LiteralPath $Extracted) { Remove-Item -LiteralPath $Extracted -Recurse -Force }
    $Encoded = @'
__ARCHIVE__
'@
    [IO.File]::WriteAllBytes($ZipPath, [Convert]::FromBase64String(($Encoded -replace '\s', '')))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Extracted)

    # Overrides are loaded before derived variables by 00-config.ps1.
    $OverrideText = @(
        ('$Server = "{0}"' -f $Server),
        ('$RemoteFolder = "{0}"' -f $RemoteFolder),
        '$ProxyServer = $Server'
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $Extracted '00-local-settings.ps1') -Value $OverrideText -Encoding ASCII

    # The worker and its retries are registered BEFORE any network transfer.
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $DeployScript = Join-Path $Extracted '11-deployment-launch-worker.ps1'
    $ActionArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $DeployScript + '"'
    $Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $ActionArgs -WorkingDirectory $Extracted
    $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $Startup = New-ScheduledTaskTrigger -AtStartup
    $Retry = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(15) -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 365)
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger @($Startup, $Retry) -Principal $Principal -Settings $Settings -Force | Out-Null

    # Durable launch receipt for one-shot status checks before engine state is created.
    Set-Content -LiteralPath "$ModePath.tmp" -Value $BootstrapMode -Encoding ASCII
    Move-Item -LiteralPath "$ModePath.tmp" -Destination $ModePath -Force
    $Receipt = [pscustomobject]@{
        Package = $RemoteFolder
        Server = $Server
        RequestedMode = $BootstrapMode
        Status = 'Queued'
        TaskName = $TaskName
        RequestedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    $Receipt | ConvertTo-Json | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8
    $ReceiptCreatedThisRun = $true
    Set-Content -LiteralPath $ActiveFile -Value $RemoteFolder -Encoding ASCII
    try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop }
    catch { Write-Warning "Immediate launch failed; startup/periodic trigger remains registered: $($_.Exception.Message)" }
    if ($BootstrapMode -eq 'DownloadOnly') {
        Write-Host "QUEUED_DOWNLOAD: $RemoteFolder. Files will be downloaded and verified locally."
    } else {
        Write-Host "QUEUED_DEPLOY: $RemoteFolder. Download and installation will continue locally."
    }
    Write-Host "Launch task: $TaskName"
    Write-Host "Status file: $StatePath"
    Write-Host 'Launch accepted != deployment completed. Run 10-vrx-check-status.ps1 separately to check progress.'
    exit 0
} catch {
    # Mark a failed dispatch as Failed rather than leaving an ambiguous Queued receipt.
    if ($ReceiptCreatedThisRun -and $null -ne $ReceiptPath -and (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        try {
            $FailedReceipt = [pscustomobject]@{
                Package = $RemoteFolder
                Server = $Server
                RequestedMode = $BootstrapMode
                Status = 'Failed'
                TaskName = $TaskName
                Error = $_.Exception.Message
                LastUpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
            }
            $FailedReceipt | ConvertTo-Json | Set-Content -LiteralPath $ReceiptPath -Encoding UTF8
        } catch {}
    }
    Write-Error "vRx bootstrap failed: $($_.Exception.Message)"
    exit 1
} finally {
    if ($HasBootstrapMutex) { $BootstrapMutex.ReleaseMutex() }
    if ($null -ne $BootstrapMutex) { $BootstrapMutex.Dispose() }
}
'''
bootstrap = bootstrap.replace('__ARCHIVE__', wrapped)
out = CLIENT / '09-vrx-bootstrap.ps1'
out.write_text(bootstrap, encoding='utf8')
print('Generated:', out, out.stat().st_size, 'bytes')
