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
