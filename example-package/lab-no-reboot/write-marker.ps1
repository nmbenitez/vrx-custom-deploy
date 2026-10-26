# Safe lab example: creates a marker file and exits successfully.
$Marker = 'C:\ProgramData\vRxDeploy\lab-no-reboot\lab-marker.txt'
New-Item -ItemType Directory -Path (Split-Path -Parent $Marker) -Force | Out-Null
Set-Content -LiteralPath $Marker -Value (Get-Date -Format o) -Encoding ASCII
Write-Host "Marker created: $Marker"
exit 0
