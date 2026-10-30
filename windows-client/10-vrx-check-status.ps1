#Requires -Version 5.1
# ============================================
# Configuration
# ============================================
$RemoteFolder = "example-package"
$EngineRoot = "C:\ProgramData\vRxDeploy"

# ============================================
# Derived paths
# ============================================
$StateDir = Join-Path $EngineRoot $RemoteFolder
$StatePath = Join-Path $StateDir "deployment-state.json"
$LaunchReceipt = Join-Path $StateDir "launch-receipt.json"
$ModePath = Join-Path $StateDir "requested-mode.txt"
$ErrorActionPreference = "Stop"

# ============================================
# Read status: one execution, no waiting
# ============================================
try {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        if (Test-Path -LiteralPath $LaunchReceipt -PathType Leaf) {
            $LaunchState = Get-Content -LiteralPath $LaunchReceipt -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host "$($LaunchState.Status): $RemoteFolder (engine state not created yet)"
            if (Test-Path -LiteralPath $ModePath -PathType Leaf) {
                Write-Host "RequestedMode: $((Get-Content -LiteralPath $ModePath -Raw -Encoding ASCII).Trim())"
            }
            if ($LaunchState.LastUpdatedAt) { Write-Host "LastUpdatedAt: $($LaunchState.LastUpdatedAt)" }
            if ($LaunchState.Error) { Write-Host "LastError: $($LaunchState.Error)" }
            if ($LaunchState.Status -eq 'Failed') { exit 1 }
        } else {
            Write-Host "NOT_STARTED: $RemoteFolder"
        }
        exit 2
    }

    $State = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "Package: $($State.Package)"
    Write-Host "Status: $($State.Status)"
    Write-Host "NextStep: $($State.NextStep)"
    Write-Host "LastExitCode: $($State.LastExitCode)"
    Write-Host "UpdatedAt: $($State.UpdatedAt)"

    $StepName = if (-not [string]::IsNullOrWhiteSpace([string]$State.CurrentStepLabel)) {
        [string]$State.CurrentStepLabel
    } else {
        [string]$State.CurrentStepId
    }
    if ($State.Status -eq 'Failed') {
        if ($StepName) { Write-Host "FailedStep: $StepName (id: $($State.CurrentStepId), type: $($State.CurrentStepType))" }
        if ($State.LastError) { Write-Host "LastError: $($State.LastError)" }
    } elseif ($State.Status -ne 'Completed') {
        if ($StepName) { Write-Host "PendingStep: $StepName (id: $($State.CurrentStepId), type: $($State.CurrentStepType))" }
        if ($State.Status -eq 'WaitingForUser') { Write-Host 'PendingReason: waiting for a user to sign in.' }
    }

    if ($State.Status -eq "Completed") { exit 0 }
    if ($State.Status -eq "Failed") { exit 1 }
    exit 2
}
catch {
    Write-Error "Status check failed: $($_.Exception.Message)"
    exit 1
}
