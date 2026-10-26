#Requires -Version 5.1
# ============================================
# Configuration
# ============================================
. "$PSScriptRoot\00-config.ps1"

# ============================================
# Read persisted status (safe for vRx polling)
# ============================================
try {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        $Receipt = Join-Path $StateDir "launch-receipt.json"
        if (Test-Path -LiteralPath $Receipt -PathType Leaf) {
            $LaunchState = Get-Content -LiteralPath $Receipt -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host "$($LaunchState.Status): $RemoteFolder (engine state not created yet)"
            if ($LaunchState.Status -eq 'Failed') { exit 1 }
        } else {
            Write-Host "NOT_STARTED: $RemoteFolder"
        }
        exit 2
    }
    $State = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "Package: $($State.Package)"
    Write-Host "Status: $($State.Status)"
    Write-Host "Next step index: $($State.NextStep)"
    Write-Host "Last exit code: $($State.LastExitCode)"
    Write-Host "Updated: $($State.UpdatedAt)"
    if ($State.Status -eq 'Completed') { exit 0 }
    if ($State.Status -eq 'Failed') { exit 1 }
    exit 2
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
