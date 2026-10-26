# ============================================
# Manifest helpers - Windows PowerShell 5.1
# No command-line parameters; uses shared configuration.
# ============================================

function Read-ManifestEntries {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }
    $Found = New-Object 'System.Collections.Generic.List[object]'
    $Seen = @{}
    foreach ($Line in @(Get-Content -LiteralPath $ManifestPath -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        $Parts = $Line -split '\|', 3
        if ($Parts.Count -ne 3) { throw "Invalid manifest record: $Line" }
        $Rel = [string]$Parts[0]
        # Only portable filenames. Prevent path traversal, escaping and ambiguous paths.
        if ($Rel -notmatch '^[A-Za-z0-9_. /-]+$' -or $Rel -match '(^|/)\.{1,2}(/|$)' -or $Rel -match '//|/$' -or $Rel.StartsWith('/')) {
            throw "Unsupported/unsafe manifest path: $Rel"
        }
        foreach ($Part in ($Rel -split '/')) {
            if ($Part.EndsWith(' ') -or $Part.EndsWith('.') -or $Part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
                throw "Unsafe Windows filename: $Rel"
            }
        }
        $Key = $Rel.ToLowerInvariant()
        if ($Seen.ContainsKey($Key)) { throw "Duplicate manifest path: $Rel" }
        $Seen[$Key] = $true
        [long]$Size = -1
        if (-not [long]::TryParse($Parts[1], [ref]$Size) -or $Size -lt 0 -or $Parts[2] -notmatch '^[a-fA-F0-9]{64}$') {
            throw "Invalid metadata in manifest: $Rel"
        }
        $Found.Add([pscustomobject]@{ Path = $Rel; Size = $Size; Hash = $Parts[2].ToUpperInvariant() })
    }
    return $Found.ToArray()
}

function Get-PackageEntries {
    if ($RemoteFolder -notmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*$') {
        throw "Invalid package directory: $RemoteFolder"
    }
    $Prefix = "$RemoteFolder/"
    $All = @(Read-ManifestEntries)
    $Selected = @($All | Where-Object { $_.Path.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($Selected.Count -eq 0) { throw "No manifest entries for package: $RemoteFolder" }
    if (@($Selected | Where-Object { $_.Path -ceq "$RemoteFolder/deployment.json" }).Count -eq 0) {
        throw "Package is missing deployment.json in manifest: $RemoteFolder"
    }
    return $Selected
}

function Test-ExpectedFile {
    if (-not (Test-Path -LiteralPath $CurrentLocalPath -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $CurrentLocalPath).Length -ne $CurrentEntry.Size) { return $false }
    return ((Get-FileHash -LiteralPath $CurrentLocalPath -Algorithm SHA256).Hash -eq $CurrentEntry.Hash)
}

function Get-CurrentDownloadUrl {
    $Segments = @($CurrentEntry.Path -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) })
    return "$BaseUrl/$($Segments -join '/')"
}
