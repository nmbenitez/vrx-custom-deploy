#Requires -Version 5.1
# ============================================
# Configuration - standalone vRx speed test, no deployment
# ============================================
$Server = "192.0.2.10"
$RemoteFolder = "example-package"
$FileName = "2026mayo30-CopiaArchivos.EXE"
$BenchmarkRoot = "C:\ProgramData\vRxDeploy\download-benchmark"
$RunCurlTest = $true
$RunInvokeWebRequestTest = $true
$CurlBypassProxy = $true

# ============================================
# Initialization
# ============================================
$ErrorActionPreference = "Stop"
try {
    if ($Server -notmatch '^[A-Za-z0-9.:-]+$' -or $RemoteFolder -notmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$' -or $FileName -notmatch '^[A-Za-z0-9_. -]+$') {
        throw 'Invalid server/package/file configuration.'
    }
    if (-not $RunCurlTest -and -not $RunInvokeWebRequestTest) { throw 'Enable at least one download test.' }
    $BaseUrl = "http://$Server/packages"
    $Relative = "$RemoteFolder/$FileName"
    $DownloadUrl = "$BaseUrl/$([Uri]::EscapeDataString($RemoteFolder))/$([Uri]::EscapeDataString($FileName))"
    $ManifestUrl = "$BaseUrl/manifest.txt"
    New-Item -ItemType Directory -Path $BenchmarkRoot -Force | Out-Null

    Write-Host "Benchmarking: $Relative"
    Write-Host "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    Write-Host "Manifest: $ManifestUrl"
    $ManifestClock = [Diagnostics.Stopwatch]::StartNew()
    $Manifest = Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -ErrorAction Stop
    $ManifestClock.Stop()
    Write-Host "Manifest request: $([Math]::Round($ManifestClock.Elapsed.TotalSeconds,2)) s (Invoke-WebRequest)"

    $MatchingLine = @(([string]$Manifest.Content -split "`n") | Where-Object {
        ($_ -split '\|', 2)[0].Trim() -ceq $Relative
    })
    if ($MatchingLine.Count -ne 1) { throw "Expected exactly one manifest entry for: $Relative (found $($MatchingLine.Count))." }
    $Parts = $MatchingLine[0].Trim() -split '\|', 3
    if ($Parts.Count -ne 3 -or $Parts[2] -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid manifest record.' }
    [long]$ExpectedSize = 0
    if (-not [long]::TryParse($Parts[1], [ref]$ExpectedSize) -or $ExpectedSize -lt 0) { throw 'Invalid manifest file size.' }
    $ExpectedHash = $Parts[2]

    $CurlPath = $null
    foreach ($Candidate in @((Join-Path $env:SystemRoot 'Sysnative\curl.exe'), (Join-Path $env:SystemRoot 'System32\curl.exe'))) {
        if (Test-Path -LiteralPath $Candidate -PathType Leaf) { $CurlPath = $Candidate; break }
    }
    $Methods = @()
    if ($RunInvokeWebRequestTest) { $Methods += 'InvokeWebRequest' }
    if ($RunCurlTest) { $Methods += 'Curl' }
    $Failed = 0

    foreach ($Method in $Methods) {
        $Target = Join-Path $BenchmarkRoot ("test-" + $Method + ".download")
        Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
        try {
            Write-Host '--------------------------------------------'
            Write-Host "Download method: $Method"
            $Clock = [Diagnostics.Stopwatch]::StartNew()
            if ($Method -eq 'Curl') {
                if (-not $CurlPath) { throw 'Windows curl.exe not found.' }
                $Arguments = @('--fail', '--silent', '--show-error', '--connect-timeout', '15', '--output', $Target)
                if ($CurlBypassProxy) { $Arguments += @('--noproxy', '*') }
                $Arguments += $DownloadUrl
                & $CurlPath @Arguments
                if ($LASTEXITCODE -ne 0) { throw "curl.exe exit code $LASTEXITCODE" }
            } else {
                Invoke-WebRequest -Uri $DownloadUrl -OutFile $Target -UseBasicParsing -ErrorAction Stop
            }
            $Clock.Stop()
            if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { throw 'Download did not create the file.' }
            [long]$Bytes = (Get-Item -LiteralPath $Target).Length
            $Speed = ($Bytes / 1MB) / [Math]::Max($Clock.Elapsed.TotalSeconds, 0.001)
            Write-Host ("Transfer: {0:N2} MiB | {1:N2} s | {2:N2} MiB/s" -f ($Bytes / 1MB), $Clock.Elapsed.TotalSeconds, $Speed)
            $HashClock = [Diagnostics.Stopwatch]::StartNew()
            $Valid = ($Bytes -eq $ExpectedSize) -and ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -eq $ExpectedHash)
            $HashClock.Stop()
            if (-not $Valid) { throw 'Downloaded file did not match manifest (size/SHA256).' }
            Write-Host "SHA256: OK ($([Math]::Round($HashClock.Elapsed.TotalSeconds,2)) s)"
        } catch {
            $Failed++
            Write-Warning "$Method failed: $($_.Exception.Message)"
        } finally {
            Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host 'Benchmark finished. No package installation was started.'
    Write-Host 'Caution: HTTP caching, disk caching and different proxy paths can influence results.'
    if ($Failed -gt 0) { exit 1 }
    exit 0
} catch {
    Write-Error "Benchmark failed: $($_.Exception.Message)"
    exit 1
}
