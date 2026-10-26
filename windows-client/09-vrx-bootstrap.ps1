#Requires -Version 5.1
# ============================================
# Configuration - edit the same script stored in vRx before each launch
# ============================================
$Server = ""                          # Set the Ubuntu address once in vRx
$RemoteFolder = ""                    # Set the published package for this launch
$BootstrapMode = "DownloadOnly"       # DownloadOnly first, Deploy later
$EngineRoot = "C:\ProgramData\vRxDeploy"
$BootstrapRoot = "C:\ProgramData\vRxDeploy\bootstrap-v024"
# Download settings are forwarded to 00-config.ps1 through 00-local-settings.ps1.
$DownloadMethod = "Auto"           # Auto, Curl, InvokeWebRequest
$CurlBypassProxy = $true
$CurlRetryCount = 2
$CurlConnectTimeoutSeconds = 15
$CurlMaxTimeSeconds = 0
$DownloadAttempts = 2

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
'@
    [IO.File]::WriteAllBytes($ZipPath, [Convert]::FromBase64String(($Encoded -replace '\s', '')))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Extracted)

    # Overrides are loaded before derived variables by 00-config.ps1.
    $OverrideText = @(
        ('$Server = "{0}"' -f $Server),
        ('$RemoteFolder = "{0}"' -f $RemoteFolder),
        '$ProxyServer = $Server',
        ('$DownloadMethod = "{0}"' -f $DownloadMethod),
        ('$CurlBypassProxy = $' + $CurlBypassProxy.ToString().ToLowerInvariant()),
        ('$CurlRetryCount = {0}' -f $CurlRetryCount),
        ('$CurlConnectTimeoutSeconds = {0}' -f $CurlConnectTimeoutSeconds),
        ('$CurlMaxTimeSeconds = {0}' -f $CurlMaxTimeSeconds),
        ('$DownloadAttempts = {0}' -f $DownloadAttempts)
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
