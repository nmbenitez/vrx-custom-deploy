#Requires -Version 5.1
# ============================================
# Operator settings in the single action stored in vRx
# ============================================
$Server = ""                          # Set the Ubuntu address once in vRx
$RemoteFolder = ""                    # Set the published package for this launch
$BootstrapMode = "DownloadOnly"       # DownloadOnly first, Deploy later
$DownloadRoot = "C:\Infrastructure\Packages" # Local folder for verified package files

# Internal paths and retry defaults live in 00-config.ps1.
$EngineRoot = "C:\ProgramData\vRxDeploy"
$BootstrapRoot = "C:\ProgramData\vRxDeploy\bootstrap-v024"

# ============================================
# Queue persistent download or installation; return immediately to vRx
# ============================================
$ErrorActionPreference = "Stop"
$BootstrapMutex = $null
$HasBootstrapMutex = $false
$ReceiptCreatedThisRun = $false
$RegisteredLaunchTaskThisRun = $false

function Remove-TerminalTasks {
    foreach ($Name in @('vRxDeploy-Launch', 'vRxDeploy-Resume')) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
    }
}
try {
    if ($Server -notmatch '^[A-Za-z0-9.:-]+$') { throw 'Set a valid $Server in the vRx script.' }
    if ($RemoteFolder -notmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$') { throw 'Set $RemoteFolder to a published package name in the vRx script.' }
    if ($BootstrapMode -notin @('DownloadOnly','Deploy')) { throw 'Invalid bootstrap mode.' }
    if ($DownloadRoot -notmatch '^[A-Za-z]:\\' -or $DownloadRoot -match '["\r\n]') { throw 'Set $DownloadRoot to an absolute local Windows path, such as C:\Infrastructure\Packages.' }

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
        if ($Existing.Status -eq 'Completed') {
            Remove-TerminalTasks
            Write-Host "ALREADY_COMPLETED: $RemoteFolder"
            exit 0
        }
        if ($Existing.Status -eq 'Failed') {
            Remove-TerminalTasks
            throw "Previous deployment failed: $RemoteFolder. Investigate before resetting state."
        }
        if ($Existing.Status -in @('Running','WaitingForReboot')) {
            Write-Host "ALREADY_ACTIVE: $RemoteFolder ($($Existing.Status)). No duplicate launch issued."
            exit 0
        }
    }
    if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) {
        $ExistingReceipt = Get-Content -LiteralPath $ReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($ExistingReceipt.Status -eq 'Failed') {
            Remove-TerminalTasks
            throw "Previous launch failed: $RemoteFolder. Investigate before resetting state."
        }
        if ($ExistingReceipt.Package -ne $RemoteFolder) { throw 'Launch receipt belongs to a different package.' }
        if ($ExistingReceipt.Server -and $ExistingReceipt.Server -ne $Server) { throw 'The staged package belongs to a different server.' }
        $ExistingDownloadRoot = if ($ExistingReceipt.DownloadRoot) { [string]$ExistingReceipt.DownloadRoot } else { 'C:\Infrastructure\Packages' }
        if ($ExistingDownloadRoot.TrimEnd('\') -ne $DownloadRoot.TrimEnd('\')) { throw 'The staged package uses a different $DownloadRoot. Keep the same path for DownloadOnly and Deploy.' }
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
'@
    [IO.File]::WriteAllBytes($ZipPath, [Convert]::FromBase64String(($Encoded -replace '\s', '')))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Extracted)

    # Overrides are loaded before derived variables by 00-config.ps1.
    $OverrideText = @(
        ('$Server = "{0}"' -f $Server),
        ('$RemoteFolder = "{0}"' -f $RemoteFolder),
        ('$DownloadRoot = ''{0}''' -f $DownloadRoot.Replace("'", "''")),
        '$ProxyServer = $Server'
    ) -join "`r`n"
    Set-Content -LiteralPath (Join-Path $Extracted '00-local-settings.ps1') -Value $OverrideText -Encoding UTF8

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
    $RegisteredLaunchTaskThisRun = $true

    # Durable launch receipt for one-shot status checks before engine state is created.
    Set-Content -LiteralPath "$ModePath.tmp" -Value $BootstrapMode -Encoding ASCII
    Move-Item -LiteralPath "$ModePath.tmp" -Destination $ModePath -Force
    $Receipt = [pscustomobject]@{
        Package = $RemoteFolder
        Server = $Server
        DownloadRoot = $DownloadRoot
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
    if ($RegisteredLaunchTaskThisRun) {
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    }
    # Mark a failed dispatch as Failed rather than leaving an ambiguous Queued receipt.
    if ($ReceiptCreatedThisRun -and $null -ne $ReceiptPath -and (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        try {
            $FailedReceipt = [pscustomobject]@{
                Package = $RemoteFolder
                Server = $Server
                DownloadRoot = $DownloadRoot
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
