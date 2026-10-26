#Requires -Version 5.1
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
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
AAAAAA8ADwAKBAAA4EkAAAAA
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
