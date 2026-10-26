# ============================================
# Reboot manager (loaded by deployment engine)
# ============================================

function Install-ResumeTask {
    $EngineFile = Join-Path $EngineInstallDir "06-deployment-engine.ps1"
    $PowerShellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $ActionArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $EngineFile + '"'
    $Action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $ActionArgs
    $Trigger = New-ScheduledTaskTrigger -AtStartup
    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 12) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
}

function Remove-ResumeTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}

function Request-ManagedReboot {
    # Current step's completion and next step are written before the reboot.
    Install-ResumeTask
    $State.Status = "WaitingForReboot"
    $State.BootMarker = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")
    $State.UpdatedAt = (Get-Date).ToUniversalTime().ToString("o")
    Save-DeploymentState
    Write-DeploymentLog "Saved state and installed SYSTEM startup task. Requesting reboot."
    & shutdown.exe /r /t 0
    if ($LASTEXITCODE -ne 0) { throw "Windows refused reboot: $LASTEXITCODE" }
}
