[CmdletBinding()]
param(
    [string]$Wheel,
    [string]$UsbToolsPath,
    [string]$Udid
)

$ErrorActionPreference = 'Stop'
$Marker = ':: Managed by Rocam setup_windows.ps1'
$DataDir = Join-Path $env:LOCALAPPDATA 'Rocam'
$StartupFile = Join-Path ([Environment]::GetFolderPath('Startup')) 'Rocam USB Receiver.cmd'
$ScriptDir = Split-Path -Parent $PSCommandPath
$ReleaseApi = 'https://api.github.com/repos/ryanjin333/robocam/releases/latest'

function Fail([string]$Message) { throw "Rocam setup: $Message" }
function Invoke-Checked([scriptblock]$Action, [string]$Name) {
    & $Action
    if ($LASTEXITCODE -ne 0) { Fail "$Name failed (exit $LASTEXITCODE)" }
}
function Test-OwnedFile([string]$Path) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and -not ((Get-Item -LiteralPath $Path).LinkType) -and
        ((Get-Content -LiteralPath $Path -TotalCount 1) -eq $Marker)
}
function Assert-SafePath([string]$Path) {
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).LinkType) { Fail "refusing symbolic-link destination: $Path" }
}
function Install-WingetPackage([string]$Id, [string]$Source = 'winget') {
    & winget install --id $Id --exact --source $Source --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { Fail "winget could not install $Id" }
}
function Get-ReleaseAsset([string]$Name, [string]$Destination) {
    $release = Invoke-RestMethod -Uri $ReleaseApi -Headers @{ 'Accept' = 'application/vnd.github+json' }
    $asset = $release.assets | Where-Object name -eq $Name | Select-Object -First 1
    if (-not $asset) { Fail "the latest Rocam release does not contain $Name" }
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $Destination
}
function Expand-VerifiedZip([string]$Zip, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            if ([IO.Path]::IsPathRooted($entry.FullName) -or $entry.FullName -match '(^|[\\/])\.\.([\\/]|$)') { Fail 'release USB tools archive contains an unsafe path' }
        }
    } finally { $archive.Dispose() }
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
}
function Get-UsbTools([string]$RequestedPath) {
    if ($RequestedPath) { return $RequestedPath }
    $bundled = Join-Path $ScriptDir 'usb-tools\bin'
    if (Test-Path -LiteralPath (Join-Path $bundled 'iproxy.exe')) { return $bundled }
    $downloadDir = Join-Path $env:TEMP "rocam-usb-tools-$PID"
    New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null
    $checksums = Join-Path $downloadDir 'checksums-sha256.txt'
    $zip = Join-Path $downloadDir 'RocamUSBTools-windows-x86_64.zip'
    Get-ReleaseAsset 'checksums-sha256.txt' $checksums
    Get-ReleaseAsset 'RocamUSBTools-windows-x86_64.zip' $zip
    $expected = (Get-Content -LiteralPath $checksums | Where-Object { $_ -match 'RocamUSBTools-windows-x86_64\.zip$' } | Select-Object -First 1) -split '\s+' | Select-Object -First 1
    if (-not $expected -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected.ToUpperInvariant()) { Fail 'downloaded USB tools checksum does not match the release manifest' }
    $target = Join-Path $DataDir 'usb-tools'
    Expand-VerifiedZip $zip $target
    return (Join-Path $target 'usb-tools\bin')
}

if ($Udid -and $Udid -notmatch '^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})$') { Fail '--Udid must be a valid iPhone or iPad UDID' }
Assert-SafePath $DataDir; Assert-SafePath $StartupFile
if ((Test-Path -LiteralPath $DataDir) -and -not (Test-Path -LiteralPath (Join-Path $DataDir '.rocam-owned'))) { Fail 'existing Rocam data is not managed by this setup' }
if ((Test-Path -LiteralPath $StartupFile) -and -not (Test-OwnedFile $StartupFile)) { Fail 'existing Startup profile is not managed by this setup' }
try { $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 8765); $listener.Start(); $listener.Stop() } catch { Fail '127.0.0.1:8765 is already in use; leave the existing receiver untouched' }
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Fail 'winget is required to install Python, OBS, and Apple Devices' }
function Find-Python312 {
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) {
        try {
            $candidate = & $launcher.Source -3.12 -c 'import sys; print(sys.executable)' 2>$null
            if ($LASTEXITCODE -eq 0 -and $candidate) { return $candidate.Trim() }
        } catch { }
    }
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'),
        (Join-Path $env:ProgramFiles 'Python312\python.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}
$python = Find-Python312
if (-not $python) {
    Install-WingetPackage 'Python.Python.3.12'
    $python = Find-Python312
    if (-not $python) { Fail 'Python 3.12 is not available after installation' }
}
if (-not (Get-Command obs64.exe -ErrorAction SilentlyContinue)) { Install-WingetPackage 'OBSProject.OBSStudio' }
if (-not (Get-Service -Name AppleMobileDeviceService -ErrorAction SilentlyContinue)) { Install-WingetPackage '9NP83LWLPZ9K' 'msstore' }
if (-not $Wheel) { $Wheel = Get-ChildItem -LiteralPath $ScriptDir -Filter 'rocam_webcam-*.whl' -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
if (-not $Wheel) { $Wheel = Get-ChildItem -LiteralPath (Join-Path $ScriptDir 'dist') -Filter 'rocam_webcam-*.whl' -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
if (-not $Wheel -and (Test-Path -LiteralPath (Join-Path $ScriptDir 'pyproject.toml'))) {
    Invoke-Checked { & $python -m pip wheel --no-deps --wheel-dir (Join-Path $ScriptDir 'dist') $ScriptDir } 'building the local Rocam wheel'
    $Wheel = Get-ChildItem -LiteralPath (Join-Path $ScriptDir 'dist') -Filter 'rocam_webcam-*.whl' -File | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Wheel -or -not (Test-Path -LiteralPath $Wheel) -or -not $Wheel.EndsWith('.whl')) { Fail 'the release bundle is missing its Rocam wheel' }

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
Set-Content -LiteralPath (Join-Path $DataDir '.rocam-owned') -Value 'owned' -NoNewline
$tools = Get-UsbTools $UsbToolsPath
$iproxy = Join-Path $tools 'iproxy.exe'
if (-not (Test-Path -LiteralPath $iproxy)) { Fail 'iproxy is missing from the local or verified downloaded USB tools' }
$iproxyHelp = & $iproxy --help 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $iproxyHelp -notmatch '--local' -or $iproxyHelp -notmatch '--source') { Fail 'iproxy does not support --local and --source' }

$venv = Join-Path $DataDir 'venv'; $backup = Join-Path $DataDir "venv.backup.$PID"; $startupBackup = Join-Path $DataDir "startup.backup.$PID"
if (Test-Path -LiteralPath $venv) { Move-Item -LiteralPath $venv -Destination $backup }
if (Test-Path -LiteralPath $StartupFile) { Copy-Item -LiteralPath $StartupFile -Destination $startupBackup }
$process = $null
try {
    Invoke-Checked { & $python -m venv $venv } 'creating the Rocam virtual environment'
    Invoke-Checked { & (Join-Path $venv 'Scripts\python.exe') -m pip install --upgrade --force-reinstall $Wheel } 'installing the Rocam wheel'
    Invoke-Checked { & (Join-Path $venv 'Scripts\rocam-webcam.exe') --help | Out-Null } 'validating the Rocam receiver'
    $safeTools = $tools -replace '%', '%%'; $safeReceiver = (Join-Path $venv 'Scripts\rocam-webcam.exe') -replace '%', '%%'
    $receiverLine = '@"' + $safeReceiver + '" --usb --fps 20' + $(if ($Udid) { ' --udid ' + $Udid } else { '' })
    @($Marker, '@setlocal', '@set "PATH=' + $safeTools + ';%PATH%"', $receiverLine) | Set-Content -LiteralPath $StartupFile -Encoding ascii
    $process = Start-Process -FilePath $StartupFile -PassThru
    Start-Sleep -Seconds 2
    if ($process.HasExited) { Fail 'Rocam stopped during startup validation' }
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startupBackup -Force -ErrorAction SilentlyContinue
} catch {
    if ($process -and -not $process.HasExited) { & taskkill /pid $process.Id /t /f 2>$null | Out-Null }
    if (Test-Path -LiteralPath $StartupFile) { Remove-Item -LiteralPath $StartupFile -Force }
    if (Test-Path -LiteralPath $startupBackup) { Move-Item -LiteralPath $startupBackup -Destination $StartupFile -Force }
    if (Test-Path -LiteralPath $venv) { Remove-Item -LiteralPath $venv -Recurse -Force }
    if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $venv }
    throw
}
Write-Host 'Rocam will start from this user''s Startup folder using USB at 20 FPS.'
Write-Host 'Connect the phone by USB, unlock it, and accept Trust. AppleMobileDeviceService cannot grant that trust automatically.'
Write-Host 'OBS Virtual Camera remains a normal OBS setup step. Microphone forwarding is off.'
