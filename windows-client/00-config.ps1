# ============================================
# Configuration - edit this file only
# ============================================
$Server = "192.0.2.10"
$ProxyServer = $Server
$ProxyPort = "3128"
$RemoteFolder = "example-package"
$DownloadRoot = "C:\Infrastructure\Packages"
$EngineRoot = "C:\ProgramData\vRxDeploy"

# ============================================
# Download configuration - Windows PowerShell 5.1
# ============================================
# Auto = prefer built-in Windows curl.exe, otherwise Invoke-WebRequest
# Curl = require curl.exe; InvokeWebRequest = use the old method for A/B tests
$DownloadMethod = "Auto"
$CurlBypassProxy = $true
$CurlRetryCount = 2
$CurlConnectTimeoutSeconds = 15
$CurlMaxTimeSeconds = 0         # 0 means unlimited; large installers can take time
$DownloadAttempts = 2          # Retry after a transfer error or SHA256 mismatch
$DownloadJitterMaxSeconds = 120 # Spread retries across endpoints

# Optional utilities (single-file download and MSI installer)
$FileName = "agent.msi"
$InstallArguments = "/qn /norestart"

# Optional override created by the self-contained vRx bootstrap.
$LocalOverrides = Join-Path $PSScriptRoot "00-local-settings.ps1"
if (Test-Path -LiteralPath $LocalOverrides -PathType Leaf) { . $LocalOverrides }

# ============================================
# Derived paths - do not edit normally
# ============================================
$BaseUrl = "http://$Server/packages"
$ManifestUrl = "$BaseUrl/manifest.txt"
$ManifestPath = Join-Path $DownloadRoot "manifest.txt"
$DestinationFolder = Join-Path $DownloadRoot $RemoteFolder
$StateDir = Join-Path $EngineRoot $RemoteFolder
$StatePath = Join-Path $StateDir "deployment-state.json"
$ModePath = Join-Path $StateDir "requested-mode.txt"
$LogPath = Join-Path $StateDir "deployment.log"
$EngineInstallDir = Join-Path $EngineRoot "engine"
$TaskName = "vRxDeploy-Resume"
$LaunchTaskName = "vRxDeploy-Launch"
$ErrorActionPreference = "Stop"
