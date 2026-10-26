#Requires -Version 5.1
# ============================================
# Configuration
# ============================================
. "$PSScriptRoot\00-config.ps1"
$ProxyAddress = "$ProxyServer`:$ProxyPort"

# ============================================
# Configure WinHTTP proxy
# ============================================
Write-Host "Configuring WinHTTP proxy: $ProxyAddress"
# Keep Ubuntu Nginx downloads on the LAN, outside Squid.
& netsh.exe winhttp set proxy "proxy-server=$ProxyAddress" "bypass-list=$ProxyServer;<local>"
if ($LASTEXITCODE -ne 0) { throw "WinHTTP proxy configuration failed: $LASTEXITCODE" }
& netsh.exe winhttp show proxy
