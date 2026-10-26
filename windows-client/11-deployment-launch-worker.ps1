#Requires -Version 5.1
# ============================================
# Persistent download and launch worker
# ============================================
. "$PSScriptRoot\00-config.ps1"
$ReceiptPath = Join-Path $StateDir 'launch-receipt.json'
$WorkerLog = Join-Path $StateDir 'launch-worker.log'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Mutex = $null
$HasMutex = $false
$TranscriptStarted = $false

function Remove-LaunchTask {
    Unregister-ScheduledTask -TaskName $LaunchTaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Remove-TerminalTasks {
    Remove-LaunchTask
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Get-RequestedMode {
    if (Test-Path -LiteralPath $ModePath -PathType Leaf) {
        $Mode = (Get-Content -LiteralPath $ModePath -Raw -Encoding ASCII).Trim()
    } elseif ($null -ne $Receipt -and $Receipt.RequestedMode) {
        $Mode = [string]$Receipt.RequestedMode
    } else {
        # Receipts created before two-phase support always requested deployment.
        $Mode = 'Deploy'
    }
    if ($Mode -notin @('DownloadOnly','Deploy')) { throw "Invalid requested mode: $Mode" }
    return $Mode
}

function Save-LaunchReceipt {
    $Receipt | Add-Member -NotePropertyName RequestedMode -NotePropertyValue (Get-RequestedMode) -Force
    $Receipt | Add-Member -NotePropertyName LastUpdatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    $Temporary = "$ReceiptPath.tmp"
    $Receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Temporary -Encoding UTF8
    Move-Item -LiteralPath $Temporary -Destination $ReceiptPath -Force
}

try {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $Mutex = New-Object System.Threading.Mutex($false, 'Global\vRxDeploymentLaunch')
    $HasMutex = $Mutex.WaitOne(0)
    if (-not $HasMutex) { exit 0 }
    Start-Transcript -Path $WorkerLog -Append -ErrorAction Stop | Out-Null
    $TranscriptStarted = $true

    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'Launch receipt is missing.' }
    $Receipt = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Receipt.Status -eq 'Failed') { exit 1 }
    if ($Receipt.Status -eq 'Staged' -and (Get-RequestedMode) -eq 'DownloadOnly') {
        Write-Host 'Package already staged. Waiting for a Deploy bootstrap request.'
        exit 0
    }
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $Existing = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "Engine already started: $($Existing.Status)"
        exit 0
    }

    $JitterSeconds = Get-Random -Minimum 0 -Maximum ($DownloadJitterMaxSeconds + 1)
    if ($JitterSeconds -gt 0) { Start-Sleep -Seconds $JitterSeconds }
    $Receipt.Status = 'Downloading'
    Save-LaunchReceipt
    Import-Module (Join-Path $PSScriptRoot '02-package-download.psm1') -Force
    try { Invoke-PackageDownload } catch {
        Write-Warning $_.Exception.Message
        $Receipt.Status = 'RetryScheduled'
        $Receipt | Add-Member -NotePropertyName Error -NotePropertyValue 'Download interrupted or repository unavailable; the scheduled task will retry.' -Force
        Save-LaunchReceipt
        exit 2
    }

    $Verifier = Join-Path $PSScriptRoot '03-verify-package.ps1'
    & $PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Verifier
    if ($LASTEXITCODE -ne 0) {
        $Receipt.Status = 'RetryScheduled'
        $Receipt | Add-Member -NotePropertyName Error -NotePropertyValue 'Package verification failed; retry scheduled.' -Force
        Save-LaunchReceipt
        exit 2
    }

    if ((Get-RequestedMode) -eq 'DownloadOnly') {
        $Receipt.Status = 'Staged'
        $Receipt | Add-Member -NotePropertyName Error -NotePropertyValue '' -Force
        Save-LaunchReceipt
        Write-Host 'STAGED: all package files verified. Installation is waiting for a Deploy bootstrap request.'
        if ((Get-RequestedMode) -eq 'DownloadOnly') { exit 0 }
    }

    $Receipt.Status = 'ReadyToInstall'
    $Receipt | Add-Member -NotePropertyName Error -NotePropertyValue '' -Force
    Save-LaunchReceipt
    Start-Sleep -Seconds 15
    $DeployScript = Join-Path $PSScriptRoot '12-start-staged-deployment.ps1'
    & $PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $DeployScript
    if ($LASTEXITCODE -ne 0) {
        $Receipt.Status = 'Failed'
        $Receipt | Add-Member -NotePropertyName Error -NotePropertyValue "Deployment engine launch failed with code $LASTEXITCODE" -Force
        Save-LaunchReceipt
        exit 1
    }
    Write-Host 'Deployment engine accepted the staged package.'
    exit 0
} catch {
    Write-Error "Launch worker failed: $($_.Exception.Message)"
    if ($null -ne $Receipt -and -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        $Receipt.Status = 'Failed'
        $Receipt | Add-Member -NotePropertyName Error -NotePropertyValue $_.Exception.Message -Force
        try { Save-LaunchReceipt } catch {}
    }
    exit 1
} finally {
    # DownloadOnly remains scheduled while staged; terminal outcomes do not.
    try {
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            $FinalState = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($FinalState.Status -in @('Completed','Failed')) { Remove-TerminalTasks }
        } elseif ($null -ne $Receipt -and $Receipt.Status -eq 'Failed') {
            Remove-TerminalTasks
        }
    } catch { Write-Warning "Scheduled task cleanup failed: $($_.Exception.Message)" }
    if ($TranscriptStarted) { Stop-Transcript | Out-Null }
    if ($HasMutex) { $Mutex.ReleaseMutex() }
    if ($null -ne $Mutex) { $Mutex.Dispose() }
}
