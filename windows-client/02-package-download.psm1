# ============================================
# Download helpers - Windows PowerShell 5.1
# Uses shared variables from 00-config.ps1 and the calling script.
# ============================================

function Select-DownloadMethod {
    if ($DownloadMethod -notin @('Auto', 'Curl', 'InvokeWebRequest')) {
        throw "Invalid DownloadMethod '$DownloadMethod'. Choose Auto, Curl or InvokeWebRequest."
    }
    if ($DownloadMethod -eq 'InvokeWebRequest') {
        $Script:SelectedDownloadMethod = 'InvokeWebRequest'
        $Script:SelectedCurlPath = $null
        return
    }

    # Use only trusted Windows locations, not curl.exe from the current directory/PATH.
    # Sysnative is the 64-bit Windows system directory when invoked by a 32-bit process.
    $Candidates = @(
        (Join-Path $env:SystemRoot 'Sysnative\curl.exe'),
        (Join-Path $env:SystemRoot 'System32\curl.exe')
    )
    $Script:SelectedCurlPath = $null
    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) {
            $Script:SelectedCurlPath = $Candidate
            break
        }
    }
    if ($null -ne $Script:SelectedCurlPath) {
        $Script:SelectedDownloadMethod = 'Curl'
        return
    }
    if ($DownloadMethod -eq 'Curl') {
        throw 'curl.exe was requested but Windows curl.exe was not found in System32/Sysnative.'
    }
    $Script:SelectedDownloadMethod = 'InvokeWebRequest'
}

function Invoke-DownloadFile {
    # Inputs from caller: $DownloadUrl, $DownloadTarget (temporary file path)
    if ([string]::IsNullOrWhiteSpace($DownloadUrl) -or [string]::IsNullOrWhiteSpace($DownloadTarget)) {
        throw 'Download URL and temporary destination must be configured.'
    }
    if ($DownloadAttempts -lt 1 -or $DownloadAttempts -gt 10) {
        throw 'DownloadAttempts must be between 1 and 10.'
    }
    if ($CurlRetryCount -lt 0 -or $CurlRetryCount -gt 10 -or $CurlConnectTimeoutSeconds -lt 1 -or $CurlMaxTimeSeconds -lt 0) {
        throw 'Invalid curl retry/timeout configuration.'
    }
    $LastDownloadError = ''
    for ($Attempt = 1; $Attempt -le $DownloadAttempts; $Attempt++) {
        $Resume = ($ResumePartialDownload -and $Script:SelectedDownloadMethod -eq 'Curl' -and
            (Test-Path -LiteralPath $DownloadTarget -PathType Leaf) -and
            (Get-Item -LiteralPath $DownloadTarget).Length -gt 0)
        if (-not $Resume) { Remove-Item -LiteralPath $DownloadTarget -Force -ErrorAction SilentlyContinue }
        [long]$StartingBytes = if ($Resume) { (Get-Item -LiteralPath $DownloadTarget).Length } else { 0 }
        $DownloadClock = [Diagnostics.Stopwatch]::StartNew()
        try {
            if ($Script:SelectedDownloadMethod -eq 'Curl') {
                $CurlArguments = @(
                    '--fail', '--silent', '--show-error',
                    '--retry', [string]$CurlRetryCount,
                    '--retry-delay', '2',
                    '--connect-timeout', [string]$CurlConnectTimeoutSeconds,
                    '--max-time', [string]$CurlMaxTimeSeconds,
                    '--output', $DownloadTarget
                )
                if ($Resume) { $CurlArguments += @('--continue-at', '-') }
                if ($CurlBypassProxy) { $CurlArguments += @('--noproxy', '*') }
                $CurlArguments += $DownloadUrl
                & $Script:SelectedCurlPath @CurlArguments
                if ($LASTEXITCODE -ne 0) {
                    $CurlCode = $LASTEXITCODE
                    if ($Resume -and $CurlCode -eq 33) { Remove-Item -LiteralPath $DownloadTarget -Force -ErrorAction SilentlyContinue }
                    throw "curl.exe exited with code $CurlCode. URL: $DownloadUrl"
                }
            } else {
                # The fallback follows PowerShell/.NET proxy configuration, unlike curl --noproxy.
                Invoke-WebRequest -Uri $DownloadUrl -OutFile $DownloadTarget -UseBasicParsing -ErrorAction Stop
            }
            $DownloadClock.Stop()
            if (-not (Test-Path -LiteralPath $DownloadTarget -PathType Leaf)) {
                throw "No file received from $DownloadUrl"
            }
            $DownloadBytes = (Get-Item -LiteralPath $DownloadTarget).Length
            $ElapsedSeconds = [Math]::Max($DownloadClock.Elapsed.TotalSeconds, 0.001)
            return [pscustomobject]@{
                Bytes = ($DownloadBytes - $StartingBytes)
                Seconds = $DownloadClock.Elapsed.TotalSeconds
                SpeedMiBs = ((($DownloadBytes - $StartingBytes) / 1MB) / $ElapsedSeconds)
                Method = $Script:SelectedDownloadMethod
            }
        } catch {
            $DownloadClock.Stop()
            $LastDownloadError = $_.Exception.Message
            if (-not $ResumePartialDownload) { Remove-Item -LiteralPath $DownloadTarget -Force -ErrorAction SilentlyContinue }
            if ($Attempt -lt $DownloadAttempts) {
                Write-Warning "Download attempt $Attempt/$DownloadAttempts failed: $LastDownloadError"
                Start-Sleep -Seconds 2
            }
        }
    }
    throw "Download failed after $DownloadAttempts attempts: $LastDownloadError"
}


# ============================================
# Package download function (PowerShell 5.1)
# ============================================
function Invoke-PackageDownload {
    . "$PSScriptRoot\00-config.ps1"
    . "$PSScriptRoot\00-manifest-helpers.ps1"
    try {
        Select-DownloadMethod
        $MethodLabel = if ($Script:SelectedDownloadMethod -eq 'Curl') {
            if ($CurlBypassProxy) { 'curl.exe (direct to Nginx; proxy bypass enabled)' }
            else { 'curl.exe (proxy settings allowed)' }
        } else { 'Invoke-WebRequest (fallback; proxy settings may apply)' }
        Write-Host "Download method: $MethodLabel"

        New-Item -ItemType Directory -Path $DownloadRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
        $ManifestTemp = "$ManifestPath.download"
        $ManifestSnapshot = Join-Path $StateDir 'manifest.txt'
        if (Test-Path -LiteralPath $ManifestSnapshot -PathType Leaf) {
            Copy-Item -LiteralPath $ManifestSnapshot -Destination $ManifestPath -Force
            Write-Host 'Reusing saved manifest for this deployment.'
        } else {
            $DownloadUrl = $ManifestUrl
            $DownloadTarget = $ManifestTemp
            Write-Host "Downloading manifest: $ManifestUrl"
            $ManifestMetrics = Invoke-DownloadFile
            Move-Item -LiteralPath $ManifestTemp -Destination $ManifestPath -Force
            Write-Host "Manifest downloaded in $([Math]::Round($ManifestMetrics.Seconds,2)) s"
        }

        $Entries = @(Get-PackageEntries)
        if (-not (Test-Path -LiteralPath $ManifestSnapshot -PathType Leaf)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
            Copy-Item -LiteralPath $ManifestPath -Destination $ManifestSnapshot -Force
        }
        Write-Host "Package: $RemoteFolder ($($Entries.Count) files)"
        $DownloadedFiles = 0
        $ReusedFiles = 0
        [long]$DownloadedBytes = 0
        [long]$ReusedBytes = 0
        $TotalTransferSeconds = 0.0
        $TotalHashSeconds = 0.0

        foreach ($CurrentEntry in $Entries) {
            $RelativeInPackage = $CurrentEntry.Path.Substring($RemoteFolder.Length + 1)
            $CurrentLocalPath = Join-Path $DestinationFolder ($RelativeInPackage -replace '/', '\')
            $Parent = Split-Path -Parent $CurrentLocalPath
            New-Item -ItemType Directory -Path $Parent -Force | Out-Null
            $HashClock = [Diagnostics.Stopwatch]::StartNew()
            if (Test-ExpectedFile) {
                $HashClock.Stop()
                $TotalHashSeconds += $HashClock.Elapsed.TotalSeconds
                $ReusedFiles++
                $ReusedBytes += $CurrentEntry.Size
                Write-Host "Already valid: $($CurrentEntry.Path) ($([Math]::Round($CurrentEntry.Size / 1MB,2)) MiB, SHA256 OK)"
                continue
            }
            $HashClock.Stop()
            $TotalHashSeconds += $HashClock.Elapsed.TotalSeconds

            $DownloadUrl = Get-CurrentDownloadUrl
            $Temp = "$CurrentLocalPath.download"
            $ResumePartialDownload = $true
            try {
                $Complete = $false
                for ($IntegrityAttempt = 1; $IntegrityAttempt -le 2; $IntegrityAttempt++) {
                    $DownloadTarget = $Temp
                    Write-Host "Downloading: $($CurrentEntry.Path) (attempt $IntegrityAttempt/2)"
                    $TransferMetrics = Invoke-DownloadFile
                    $TotalTransferSeconds += $TransferMetrics.Seconds
                    Write-Host ("Downloaded: {0} | {1:N2} MiB | {2:N2} s | {3:N2} MiB/s" -f $CurrentEntry.Path, ($TransferMetrics.Bytes / 1MB), $TransferMetrics.Seconds, $TransferMetrics.SpeedMiBs)

                    $HashClock = [Diagnostics.Stopwatch]::StartNew()
                    $SizeMatches = ((Get-Item -LiteralPath $Temp).Length -eq $CurrentEntry.Size)
                    $HashMatches = $false
                    if ($SizeMatches) {
                        $HashMatches = ((Get-FileHash -LiteralPath $Temp -Algorithm SHA256).Hash -eq $CurrentEntry.Hash)
                    }
                    $HashClock.Stop()
                    $TotalHashSeconds += $HashClock.Elapsed.TotalSeconds
                    if ($SizeMatches -and $HashMatches) {
                        Write-Host "Verified download: $($CurrentEntry.Path) (size + SHA256, $([Math]::Round($HashClock.Elapsed.TotalSeconds,2)) s)"
                        $Complete = $true
                        break
                    }
                    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
                    if ($IntegrityAttempt -lt 2) {
                        Write-Warning "Integrity mismatch; retrying: $($CurrentEntry.Path)"
                    }
                }
                if (-not $Complete) { throw "Integrity check failed after retry: $($CurrentEntry.Path)" }
                Move-Item -LiteralPath $Temp -Destination $CurrentLocalPath -Force
                $DownloadedFiles++
                $DownloadedBytes += $CurrentEntry.Size
            } finally {
                # Preserve partial downloads for the next scheduled attempt.
            }
        }
        Write-Host '============================================'
        Write-Host "Download summary: $DownloadedFiles downloaded / $ReusedFiles already valid / $($Entries.Count) total"
        Write-Host ("Transferred: {0:N2} MiB in {1:N2} s (average transfer speed: {2:N2} MiB/s)" -f ($DownloadedBytes / 1MB), $TotalTransferSeconds, (($DownloadedBytes / 1MB) / [Math]::Max($TotalTransferSeconds, 0.001)))
        Write-Host ("Reused: {0:N2} MiB | Integrity-check time in download stage: {1:N2} s" -f ($ReusedBytes / 1MB), $TotalHashSeconds)
        Write-Host 'All package files downloaded and verified.'
        return
    } catch {
        Remove-Item -LiteralPath "$ManifestPath.download" -Force -ErrorAction SilentlyContinue
        throw "Package download failed: $($_.Exception.Message)"
    }
}
