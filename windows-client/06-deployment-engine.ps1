#Requires -Version 5.1
# ============================================
# Configuration
# ============================================
. "$PSScriptRoot\00-config.ps1"
. "$PSScriptRoot\00-manifest-helpers.ps1"
$DeploymentFile = Join-Path $DestinationFolder "deployment.json"
$ManifestPath = Join-Path $StateDir "manifest.txt"  # Snapshot for reboot-safe verification.
$Mutex = $null
$HasMutex = $false
$State = $null

# ============================================
# State and logging
# ============================================
function Write-DeploymentLog {
    # Support existing $LogMessage convention and direct messages without a declared parameter list.
    $MessageToWrite = if ($args.Count -gt 0) { [string]$args[0] } else { [string]$LogMessage }
    $Line = "$(Get-Date -Format o) | $MessageToWrite"
    Add-Content -LiteralPath $LogPath -Value $Line -Encoding UTF8
    Write-Host $Line
}

function Save-DeploymentState {
    $Temp = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Temp -Encoding UTF8
    Move-Item -LiteralPath $Temp -Destination $StatePath -Force
}

function Resolve-StepFile {
    $RelativeFile = [string]$Step.file
    if ([string]::IsNullOrWhiteSpace($RelativeFile) -or $RelativeFile -notmatch '^[A-Za-z0-9_. /-]+$' -or $RelativeFile.StartsWith('/') -or $RelativeFile -match '(^|/)\.{1,2}(/|$)|//|/$') {
        throw "Invalid step file path: $RelativeFile"
    }
    $Resolved = Join-Path $DestinationFolder ($RelativeFile -replace '/', '\')
    if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) { throw "Missing executable file: $Resolved" }
    return $Resolved
}

function Check-PackageSnapshot {
    $Entries = @(Get-PackageEntries)
    foreach ($CurrentEntry in $Entries) {
        $RelativeInPackage = $CurrentEntry.Path.Substring($RemoteFolder.Length + 1)
        $CurrentLocalPath = Join-Path $DestinationFolder ($RelativeInPackage -replace '/', '\')
        if (-not (Test-ExpectedFile)) { throw "Package integrity mismatch: $($CurrentEntry.Path)" }
    }
}

# ============================================
# Initialize and execute
# ============================================
$ErrorActionPreference = "Stop"
try {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $Mutex = [System.Threading.Mutex]::new($false, 'Global\vRxDeploymentEngine')
    $HasMutex = $Mutex.WaitOne(0)
    if (-not $HasMutex) { throw 'Another deployment engine instance is already running.' }

    if (-not (Test-Path -LiteralPath $DeploymentFile -PathType Leaf)) { throw "Missing deployment.json: $DeploymentFile" }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { throw "Missing saved manifest: $ManifestPath" }
    $Deployment = Get-Content -LiteralPath $DeploymentFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Deployment.name -cne $RemoteFolder) { throw 'deployment.json name does not match selected package.' }
    $Steps = @($Deployment.steps)
    if ($Steps.Count -eq 0) { throw 'deployment.json has no steps.' }
    $Ids = @{}
    foreach ($Step in $Steps) {
        if ([string]::IsNullOrWhiteSpace($Step.id) -or $Ids.ContainsKey([string]$Step.id)) { throw 'Missing or duplicate step ID.' }
        $Ids[[string]$Step.id] = $true
        if ($Step.type -notin @('reboot','exe','msi','bat','ps1','vbs')) { throw "Unsupported step type: $($Step.type)" }
        if ($Step.type -ne 'reboot') { $null = Resolve-StepFile }
    }
    $Fingerprint = (Get-FileHash -LiteralPath $DeploymentFile -Algorithm SHA256).Hash

    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $State = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($State.Fingerprint -ne $Fingerprint) { throw 'Deployment definition changed after execution began.' }
    } else {
        $State = [pscustomobject]@{
            Package = $RemoteFolder
            Fingerprint = $Fingerprint
            NextStep = 0
            Status = 'Running'
            BootMarker = ''
            LastExitCode = $null
            UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
        }
        Save-DeploymentState
    }

    if ($State.Status -eq 'Completed') { $LogMessage = 'Already completed.'; Write-DeploymentLog; Remove-ResumeTask; exit 0 }
    if ($State.Status -eq 'Failed') { throw 'Previous attempt failed. Inspect log and state; explicit reset required.' }
    if ($State.Status -eq 'WaitingForReboot') {
        $CurrentBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        if ($CurrentBoot -eq $State.BootMarker) {
            $LogMessage = 'Reboot still pending; not executing next step on same boot.'
            Write-DeploymentLog
            exit 0
        }
        $State.Status = 'Running'
        $State.UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
        Save-DeploymentState
        $LogMessage = 'Resumed after reboot.'
        Write-DeploymentLog
    }

    Check-PackageSnapshot
    . "$PSScriptRoot\07-reboot-manager.ps1"

    for ($Index = [int]$State.NextStep; $Index -lt $Steps.Count; $Index++) {
        $Step = $Steps[$Index]
        $LogMessage = "Starting step $($Index + 1)/$($Steps.Count): $($Step.id) ($($Step.type))"
        Write-DeploymentLog

        if ($Step.type -eq 'reboot') {
            $RebootDelay = 0
            if ($null -ne $Step.rebootDelaySeconds -and
                -not [int]::TryParse([string]$Step.rebootDelaySeconds, [ref]$RebootDelay)) {
                throw "Invalid reboot delay in step $($Step.id)."
            }
            $RebootMessage = [string]$Step.rebootMessage
            $State.NextStep = $Index + 1
            $LogMessage = "Managed reboot step completed: $($Step.id)"
            Write-DeploymentLog
            Request-ManagedReboot -DelaySeconds $RebootDelay -Message $RebootMessage
            exit 0
        }

        $ExecutableFile = Resolve-StepFile
        $Arguments = [string]$Step.arguments
        $WindowStyle = if ($Step.windowStyle -in @('Hidden','Normal','Minimized')) { [string]$Step.windowStyle } else { 'Hidden' }
        switch ($Step.type) {
            'msi' {
                $Executable = 'msiexec.exe'
                # Force /norestart to retain ownership of restarts.
                $Arguments = '/i "' + $ExecutableFile + '" ' + $Arguments + ' /norestart'
            }
            'exe' { $Executable = $ExecutableFile }
            'bat' {
                $Executable = $env:ComSpec
                $Arguments = '/d /c ""' + $ExecutableFile + '" ' + $Arguments + '"'
            }
            'ps1' {
                $Executable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $ExecutableFile + '" ' + $Arguments
            }
            'vbs' {
                $Executable = Join-Path $env:SystemRoot 'System32\cscript.exe'
                $Arguments = '//nologo "' + $ExecutableFile + '" ' + $Arguments
            }
        }

        $Process = Start-Process -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $DestinationFolder -Wait -PassThru -WindowStyle $WindowStyle
        $Code = [int]$Process.ExitCode
        $AllowedCodes = if ($null -ne $Step.successCodes) { @($Step.successCodes | ForEach-Object { [int]$_ }) } else { @(0, 3010) }
        $LogMessage = "Step $($Step.id) finished with exit code $Code"
        Write-DeploymentLog

        if ($Code -eq 1641) { throw 'Installer rebooted itself (1641). Configure it to suppress automatic reboots.' }
        if ($Code -notin $AllowedCodes) { throw "Step $($Step.id) failed with exit code $Code" }

        $State.NextStep = $Index + 1
        $State.LastExitCode = $Code
        $State.UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
        Save-DeploymentState

        if ($Code -eq 3010) {
            if (($Index + 1) -lt $Steps.Count -and $Steps[$Index + 1].type -eq 'reboot') {
                $LogMessage = "Step $($Step.id) needs a reboot (3010); next configured reboot step will handle it."
                Write-DeploymentLog
                continue
            }
            $LogMessage = "Step $($Step.id) needs a reboot (3010)."
            Write-DeploymentLog
            Request-ManagedReboot
            exit 0
        }
    }

    $State.Status = 'Completed'
    $State.UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Save-DeploymentState
    Remove-ResumeTask
    $LogMessage = 'DEPLOYMENT COMPLETED: all configured steps succeeded; final product detection is not yet implemented.'
    Write-DeploymentLog
    exit 0
} catch {
    $Failure = $_.Exception.Message
    $LogMessage = "DEPLOYMENT ERROR: $Failure"
    Write-DeploymentLog
    if ($null -ne $State) {
        $State.Status = 'Failed'
        $State.UpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
        try { Save-DeploymentState } catch {}
    }
    # Don't cancel the resume task if a reboot was already successfully requested.
    if ($null -eq $State -or $State.Status -ne 'WaitingForReboot') {
        try { Remove-ResumeTask } catch {}
    }
    exit 1
} finally {
    if ($HasMutex) { $Mutex.ReleaseMutex() }
    if ($null -ne $Mutex) { $Mutex.Dispose() }
}
