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
        if ($Existing.Status -in @('Running','WaitingForReboot','WaitingForUser')) {
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
