#Requires -Version 5.1
# ============================================
# Configuration
# ============================================
. "$PSScriptRoot\00-config.ps1"
$Url = "$BaseUrl/$([Uri]::EscapeDataString($FileName))"
$Destination = Join-Path $env:TEMP $FileName

# ============================================
# Download diagnostic under current identity
# ============================================
Write-Host "Identity: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "WinHTTP proxy:"
& netsh.exe winhttp show proxy
Write-Host "Proxy environment variables:"
Get-ChildItem Env: | Where-Object { $_.Name -match "proxy" }
$Stopwatch = [Diagnostics.Stopwatch]::StartNew()
try {
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    $Stopwatch.Stop()
    $SizeMB = (Get-Item -LiteralPath $Destination).Length / 1MB
    $Secs = [Math]::Max(0.001, $Stopwatch.Elapsed.TotalSeconds)
    Write-Host "Size: $([Math]::Round($SizeMB,2)) MiB"
    Write-Host "Time: $([Math]::Round($Secs,2)) seconds"
    Write-Host "Speed: $([Math]::Round($SizeMB/$Secs,2)) MiB/s"
    exit 0
} catch {
    Write-Error "Diagnostic download failed: $($_.Exception.Message)"
    exit 1
}
