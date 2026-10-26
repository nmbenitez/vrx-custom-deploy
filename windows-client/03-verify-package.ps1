#Requires -Version 5.1
# ============================================
# Configuration
# ============================================
. "$PSScriptRoot\00-config.ps1"
. "$PSScriptRoot\00-manifest-helpers.ps1"

# ============================================
# Verify every file in a package
# ============================================
try {
    $Entries = @(Get-PackageEntries)
    $VerifyClock = [Diagnostics.Stopwatch]::StartNew()
    [long]$VerifiedBytes = 0
    foreach ($CurrentEntry in $Entries) {
        $RelativeInPackage = $CurrentEntry.Path.Substring($RemoteFolder.Length + 1)
        $CurrentLocalPath = Join-Path $DestinationFolder ($RelativeInPackage -replace '/', '\')
        if (-not (Test-ExpectedFile)) { throw "Missing or modified: $($CurrentEntry.Path)" }
        $VerifiedBytes += $CurrentEntry.Size
        Write-Host "Verified: $($CurrentEntry.Path)"
    }
    $VerifyClock.Stop()
    Write-Host ("Final verification: {0:N2} MiB SHA256 checked in {1:N2} s" -f ($VerifiedBytes / 1MB), $VerifyClock.Elapsed.TotalSeconds)
    Write-Host "Package verification successful ($($Entries.Count) files)."
    exit 0
} catch {
    Write-Error "Package verification failed: $($_.Exception.Message)"
    exit 1
}
