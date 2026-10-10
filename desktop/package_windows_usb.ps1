[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsysRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$SourceMirror = 'https://repo.msys2.org/mingw/sources'
)

$ErrorActionPreference = 'Stop'
$sourceBin = Join-Path $MsysRoot 'mingw64\bin'
$pacman = Join-Path $MsysRoot 'usr\bin\pacman.exe'
$bsdtar = Join-Path $MsysRoot 'usr\bin\bsdtar.exe'
$objdump = Join-Path $sourceBin 'objdump.exe'
$iproxy = Join-Path $sourceBin 'iproxy.exe'
if (-not (Test-Path -LiteralPath $pacman) -or -not (Test-Path -LiteralPath $bsdtar) -or -not (Test-Path -LiteralPath $objdump) -or -not (Test-Path -LiteralPath $iproxy)) {
    throw 'MSYS2 pacman, bsdtar, objdump, or the official libusbmuxd iproxy.exe is missing.'
}

$destination = Join-Path $OutputDirectory 'usb-tools\bin'
$licenses = Join-Path $OutputDirectory 'licenses'
$sources = Join-Path $OutputDirectory 'sources'
New-Item -ItemType Directory -Force -Path $destination, $licenses, $sources | Out-Null
Copy-Item -LiteralPath $iproxy -Destination $destination

# Follow only PE DLL dependencies already installed in this dedicated MSYS2 root.
$queue = [Collections.Generic.Queue[string]]::new()
$queue.Enqueue($iproxy)
$files = [Collections.Generic.List[string]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
while ($queue.Count) {
    $file = $queue.Dequeue()
    if (-not $seen.Add([IO.Path]::GetFileName($file))) { continue }
    $files.Add($file)
    $objdumpOutput = & $objdump -p $file 2>$null
    if ($LASTEXITCODE -ne 0) { throw "objdump could not inspect $file" }
    foreach ($name in ($objdumpOutput | Select-String 'DLL Name:' | ForEach-Object { ($_ -split ':', 2)[1].Trim() })) {
        $candidate = Join-Path $sourceBin $name
        if (Test-Path -LiteralPath $candidate) {
            Copy-Item -LiteralPath $candidate -Destination $destination -Force
            $queue.Enqueue($candidate)
        }
    }
}

$packageRecords = @{}
$fileRecords = @()
foreach ($file in $files) {
    $msysPath = '/' + $file.Substring($MsysRoot.Length).TrimStart('\').Replace('\', '/')
    $owner = (& $pacman -Qo $msysPath 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $owner -notmatch 'owned by ([^ ]+) ([^ ]+)') { throw "could not determine the MSYS2 package owner of $file" }
    $package = $Matches[1]
    $installed = (& $pacman -Q $package 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $installed -notmatch "^$([regex]::Escape($package))\s+(.+)$") { throw "could not determine the installed version of $package" }
    $version = $Matches[1]
    if ($package -eq 'mingw-w64-x86_64-libusbmuxd' -and $version -notmatch '^2\.1\.1-') { throw "expected libusbmuxd 2.1.1, found $version" }
    $fileRecords += [ordered]@{ path = "usb-tools/bin/$([IO.Path]::GetFileName($file))"; sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash; package = $package; version = $version }
    $packageRecords[$package] = $version
}

$sourceRecords = @()
foreach ($package in $packageRecords.Keys | Sort-Object) {
    $version = $packageRecords[$package]
    $localDescription = Join-Path $MsysRoot "var\lib\pacman\local\$package-$version\desc"
    if (-not (Test-Path -LiteralPath $localDescription)) { throw "missing installed pacman metadata for $package $version" }
    $description = Get-Content -LiteralPath $localDescription
    $baseIndex = [Array]::IndexOf([string[]]$description, '%BASE%')
    if ($baseIndex -lt 0 -or $baseIndex + 1 -ge $description.Length -or -not $description[$baseIndex + 1]) {
        throw "installed pacman metadata has no source base for $package $version"
    }
    $base = $description[$baseIndex + 1]
    $archiveName = "$base-$version.src.tar.zst"
    $sourceUrl = "$SourceMirror/$archiveName"
    $archivePath = Join-Path $sources $archiveName
    try {
        Invoke-WebRequest -Uri $sourceUrl -OutFile $archivePath -ErrorAction Stop
    } catch {
        throw "could not download the official MSYS2 source archive for $package $version"
    }
    if ((Get-Item -LiteralPath $archivePath).Length -eq 0) { throw "empty MSYS2 source archive: $sourceUrl" }
    & $bsdtar -tf $archivePath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "MSYS2 source archive is not a readable tar.zst for $package $version" }
    $sourceRecords += [ordered]@{ package = $package; base = $base; version = $version; url = $sourceUrl; sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash }

    $licenseFiles = & $pacman -Ql $package | ForEach-Object { ($_ -split '\s+', 2)[1] } | Where-Object { $_ -match '^/mingw64/share/licenses/.+' }
    if ($LASTEXITCODE -ne 0) { throw "could not list license files for $package" }
    $copiedLicense = $false
    foreach ($licensePath in $licenseFiles) {
        $hostPath = Join-Path $MsysRoot ($licensePath.TrimStart('/').Replace('/', '\'))
        if (Test-Path -LiteralPath $hostPath -PathType Leaf) {
            $relative = $licensePath.Substring('/mingw64/share/licenses/'.Length)
            $target = Join-Path $licenses "$package\$relative"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $hostPath -Destination $target -Force
            $copiedLicense = $true
        }
    }
    if (-not $copiedLicense) {
        $sourceLicenses = & $bsdtar -tf $archivePath | Where-Object { $_ -match '(^|/)(COPYING|COPYING\.LIB|LICENSE[^/]*)$' }
        if ($LASTEXITCODE -ne 0 -or -not $sourceLicenses) { throw "no license text was found for $package" }
        foreach ($sourceLicense in $sourceLicenses) {
            $target = Join-Path $licenses "$package\$(Split-Path -Leaf $sourceLicense)"
            & $bsdtar -xOf $archivePath $sourceLicense | Set-Content -LiteralPath $target -Encoding utf8
            if ($LASTEXITCODE -ne 0) { throw "could not extract license text for $package" }
        }
    }
}

$bundledIproxy = Join-Path $destination 'iproxy.exe'
$iproxyHelp = & $bundledIproxy --help 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $iproxyHelp -notmatch '--local' -or $iproxyHelp -notmatch '--source') {
    throw 'the packaged iproxy.exe does not start with the copied DLL closure or lacks USB options'
}

[ordered]@{ files = $fileRecords; packages = $packageRecords; sources = $sourceRecords } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'usb-tools-manifest.json') -Encoding utf8
@"
Rocam bundles the exact iproxy.exe and DLL closure recorded in usb-tools-manifest.json.
They are installed from MSYS2 packages; matching license files are in licenses/ and
matching MSYS2 source archives are in sources/. Source mirror: $SourceMirror
"@ | Set-Content -LiteralPath (Join-Path $OutputDirectory 'THIRD_PARTY_NOTICES.txt') -Encoding utf8
