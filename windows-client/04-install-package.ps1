#Requires -Version 5.1
# ============================================
# Configuration
# ============================================
. "$PSScriptRoot\00-config.ps1"
$FilePath = Join-Path $DownloadRoot $FileName
$MsiArguments = "/i `"$FilePath`" $InstallArguments"

# ============================================
# Install one MSI (standalone utility)
# ============================================
try {
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "Package missing: $FilePath" }
    $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList $MsiArguments -Wait -PassThru
    $Code = [int]$Process.ExitCode
    if ($Code -eq 0) { Write-Host "Installation completed."; exit 0 }
    if ($Code -eq 3010) { Write-Host "Installation completed; reboot required."; exit 0 }
    throw "MSI failed, exit code: $Code"
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
