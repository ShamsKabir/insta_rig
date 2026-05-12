# ===================================================
# insta_rig.ps1
# Automated application installer and updater for Windows.
# Downloads, installs, and updates a predefined set of
# applications with silent/unattended installation support.
# Requires elevation to Administrator privileges.
# ===================================================
param(
    # Passed automatically when the script re-launches itself elevated.
    # Controls whether a "Press Enter to close" pause is shown at the end,
    # since an auto-elevated window would otherwise close immediately.
    [switch]$AutoElevated
)

Clear-Host
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# ================================================
# Privilege Elevation
# Re-launches the script under an elevated Administrator
# session if the current process is not already elevated.
# Prefers Windows Terminal (wt.exe) when available.
# ================================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    $wt    = Get-Command wt -ErrorAction SilentlyContinue
    # Pass -AutoElevated so the relaunched elevated session knows to pause at the end.
    $relaunchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AutoElevated"
    if ($wt) {
        # Open a brand-new, separate Windows Terminal window using '-w new'.
        # The elevated session is fully independent — no shared window lifetime.
        Start-Process wt -Verb RunAs -ArgumentList "-w new $shell $relaunchArgs"
    } else {
        # No Windows Terminal available; launch the shell directly in a new elevated window.
        Start-Process $shell -Verb RunAs -ArgumentList $relaunchArgs
    }
    # Return to the interactive prompt; this terminal belongs to the user.
    Write-Host 'Elevated session launched.' -ForegroundColor DarkGray
    return
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ================================================
# Console Output Helpers
# Thin wrappers around Write-Host that apply a
# consistent colour scheme to status messages:
#   Info  = Cyan     (informational)
#   Ok    = Green    (success)
#   Warn  = Yellow   (non-fatal warning)
#   Note  = DarkGray (verbose/supplementary)
#   Err   = Red      (error)
# ================================================
function Write-Info { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Note { param([string]$Message) Write-Host $Message -ForegroundColor DarkGray }
function Write-Err { param([string]$Message) Write-Host $Message -ForegroundColor Red }
# ================================================
# Progress Bar
# Renders a two-line progress indicator directly to
# the console buffer. Supports both determinate mode
# (0–100 %) and indeterminate mode (Percent = -1).
# Row position is stored in $script:_pbRow so that
# subsequent redraws overwrite the same lines.
# ================================================
$script:_pbRow = -1
$script:_animTimer = $null

function Show-ProgressBar {
    param(
        [string]$Status,
        [int]$Percent = -1,
        [string]$Downloaded = '',
        [string]$Speed = ''
    )

    $winWidth = $Host.UI.RawUI.WindowSize.Width

    $stats = (@($Downloaded, $(if ($Speed) { "@ $Speed" })) | Where-Object { $_ }) -join '  '
    $pctLabel = if ($Percent -lt 0) { ' ...  ' } else { "$Percent%" }

    $statusLine = if ($stats) { "$Status  $stats" } else { $Status }
    $available = $winWidth - 10
    $line1 = if ($statusLine.Length -gt $available) {
        $statusLine.Substring(0, $available)
    }
    else {
        $statusLine.PadRight($available)
    }
    $line1 += $pctLabel.PadLeft(8)

    $barInner = [Math]::Max(10, $winWidth - 3)
    $filled = if ($Percent -lt 0) { $barInner } else {
        [Math]::Min($barInner, [int](($barInner * $Percent) / 100))
    }
    $empty = $barInner - $filled
    $bar = '|' + ([char]0x2588 -as [string]) * $filled + ([char]0x2591 -as [string]) * $empty + '|'

    if ($script:_pbRow -lt 0) {
        [Console]::WriteLine()
        [Console]::WriteLine()
        $script:_pbRow = $Host.UI.RawUI.CursorPosition.Y - 2
    }

    $isIndeterminate = $Percent -lt 0
    [Console]::SetCursorPosition(0, $script:_pbRow)
    $Host.UI.RawUI.ForegroundColor = if ($isIndeterminate) { [ConsoleColor]::DarkCyan } else { [ConsoleColor]::Cyan }
    [Console]::Write($line1)

    [Console]::SetCursorPosition(0, $script:_pbRow + 1)
    $Host.UI.RawUI.ForegroundColor = if ($isIndeterminate) { [ConsoleColor]::DarkBlue } else { [ConsoleColor]::Blue }
    [Console]::Write($bar)

    [Console]::ResetColor()
}

function Clear-ProgressBar {
    if ($script:_pbRow -lt 0) { return }
    $winWidth = $Host.UI.RawUI.WindowSize.Width
    $blank = ' ' * ($winWidth - 1)
    [Console]::SetCursorPosition(0, $script:_pbRow)
    [Console]::Write($blank)
    [Console]::SetCursorPosition(0, $script:_pbRow + 1)
    [Console]::Write($blank)
    [Console]::SetCursorPosition(0, $script:_pbRow)
    $script:_pbRow = -1
    [Console]::ResetColor()
}

# Animated scanner bar for install phases (driven by a timer-based tick loop on the main thread).
function Start-AnimatedBar {
    param([string]$Status)

    # Reserve two console lines so the row index remains stable across redraws.
    if ($script:_pbRow -lt 0) {
        [Console]::WriteLine()
        [Console]::WriteLine()
        $script:_pbRow = $Host.UI.RawUI.CursorPosition.Y - 2
    }

    $pbRow = $script:_pbRow
    $winWidth = $Host.UI.RawUI.WindowSize.Width
    $barInner = [Math]::Max(10, $winWidth - 3)
    $scanLen = [Math]::Max(6, [int]($barInner * 0.18))   

    # Render the status text line above the animated bar.
    $available = $winWidth - 10
    $line1 = if ($Status.Length -gt $available) { $Status.Substring(0, $available) } else { $Status.PadRight($available) }
    $line1 += ' ...  '.PadLeft(8)

    [Console]::SetCursorPosition(0, $pbRow)
    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::DarkCyan
    [Console]::Write($line1)
    [Console]::ResetColor()

    # Persist animation state in script scope so Stop-AnimatedBar can clean up correctly.
    $script:_animPos = 0
    $script:_animDir = 1
    $script:_animStatus = $Status
    $script:_animBarInner = $barInner
    $script:_animScanLen = $scanLen
    $script:_animPbRow = $pbRow
    $script:_animTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $script:_animLastMs = 0
}

function Invoke-AnimationTick {
    if (-not $script:_animTimer) { return }
    $now = $script:_animTimer.ElapsedMilliseconds
    if (($now - $script:_animLastMs) -lt 15) { return }
    $script:_animLastMs = $now

    $inner = $script:_animBarInner
    $scanLen = $script:_animScanLen
    $pos = $script:_animPos

    $chars = [char[]]([char]0x2591 -as [string]) * $inner
    for ($k = $pos; $k -lt ($pos + $scanLen) -and $k -lt $inner; $k++) {
        if ($k -ge 0) { $chars[$k] = [char]0x2588 }
    }
    $bar = '|' + (-join $chars) + '|'

    [Console]::SetCursorPosition(0, $script:_animPbRow + 1)
    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::Blue
    [Console]::Write($bar)
    [Console]::ResetColor()

    # Advance the scanner position; wrap back to the start when the bar end is reached.
    $script:_animPos += 1

    if ($script:_animPos -ge $inner) { 
        $script:_animPos = - $scanLen 
    }
}

function Stop-AnimatedBar {
    if ($script:_animTimer) {
        $script:_animTimer.Stop()
        $script:_animTimer = $null
    }
    Clear-ProgressBar
}

# ================================================
# ASCII Banner
# Renders the application title in two-tone ASCII art
# using Blue and DarkYellow to visually split the text.
# ================================================
Write-Host ''
$lines = @(
    '_________ _      . _______ _________ _______    _______  _________ _______',
    '\__   __/( (    /|(  ____ \\__   __/(  ___  )  (  ___  ) \__   __/(  ____ \',
    '   ) (   |  \  ( || (    \/   ) (   | (   ) |  | (   ) |    ) (   | (    \/',
    '   | |   |   \ | || (_____    | |   | (___) |  | (___) |    | |   | |       ',
    '   | |   | (\ \) |(_____  )   | |   |  ___  |  |     __)    | |   | | ____ ',
    '   | |   | | \   |      ) |   | |   | (   ) |  | (\ (       | |   | | \_  )',
    '___) (___| )  \  |/\____) |   | |   | )   ( |  | ) \ \__ ___) (___| (___) |',
    '\_______/|/    )_)\_______)   )_(   |/     \|  |/   \__/ \_______/(_______)'
)
$split = 46
foreach ($line in $lines) {
    $a = if ($line.Length -gt $split) { $line.Substring(0, $split) } else { $line }
    $b = if ($line.Length -gt $split) { $line.Substring($split) }   else { '' }
    [Console]::ForegroundColor = [ConsoleColor]::Blue
    [Console]::Write($a)
    [Console]::ForegroundColor = [ConsoleColor]::DarkYellow
    [Console]::WriteLine($b)
}
[Console]::ResetColor()
Write-Host ''

# ================================================
# Application Definitions
# Each entry is an ordered hashtable describing one
# application. Required keys: Name, Url (or
# DynamicUrlScript), FileName, Type, SilentArgs.
# Optional keys: Detect, LatestVersionScript,
# NoInstDir, AutoUpdateUrl, SkipUpdateIfInstalled.
# ================================================
$script:UninstallRegPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Get-InstalledProgramInfo {
    param(
        [Parameter(Mandatory = $true)][string[]]$MatchNames
    )

    $items = foreach ($p in $script:UninstallRegPaths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.UninstallString }
    }

    foreach ($name in $MatchNames) {
        $hit = $items | Where-Object { $_.DisplayName -like "*$name*" } | Select-Object -First 1
        if ($hit) {
            return [PSCustomObject]@{
                DisplayName     = $hit.DisplayName
                DisplayVersion  = $hit.DisplayVersion
                InstallLocation = $hit.InstallLocation
                Publisher       = $hit.Publisher
                UninstallString = $hit.UninstallString
                DisplayIcon     = $hit.DisplayIcon
            }
        }
    }
    return $null
}

function Get-InstallLocationFromUninstallEntry {
    param([pscustomobject]$RegEntry)
    if (-not $RegEntry) { return '' }
    if ($RegEntry.InstallLocation -and (Test-Path -LiteralPath $RegEntry.InstallLocation)) {
        return $RegEntry.InstallLocation
    }

    $candidates = @($RegEntry.DisplayIcon, $RegEntry.UninstallString) | Where-Object { $_ }
    foreach ($c in $candidates) {
        $s = [string]$c
        if (-not $s) { continue }

        # Extract the first quoted path; fall back to the first whitespace-delimited token.
        $path = $null
        $m = [regex]::Match($s, '"([^"]+)"')
        if ($m.Success) { $path = $m.Groups[1].Value } else { $path = ($s -split '\s+')[0] }
        $path = $path.Trim()
        if (-not $path) { continue }

        # Remove trailing commas and any extra arguments that may follow the executable path.
        $path = $path.TrimEnd(',')
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($item -and -not $item.PSIsContainer) {
                return (Split-Path -Parent $path)
            }
            if ($item -and $item.PSIsContainer) { return $path }
        }
    }

    return ''
}

function Test-DirectoryPopulated {
    param([string]$Path)
    try {
        if (-not $Path) { return $false }
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $count = (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Measure-Object).Count
        return ($count -gt 0)
    }
    catch { return $false }
}

function Get-FileVersionSafe {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $v = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
        if (-not $v) { $v = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion }
        return $v
    }
    catch { return $null }
}

function ConvertTo-VersionSafe {
    param([string]$VersionString)
    if (-not $VersionString) { return $null }
    $clean = ($VersionString -replace '[^\d\.].*$', '').Trim()
    try { return [version]$clean } catch { return $null }
}

function Get-AppInstalledInfo {
    param(
        [Parameter(Mandatory = $true)][hashtable]$App,
        [Parameter(Mandatory = $true)][string]$AppsRoot
    )

    # For ZIP-based apps, "installed" is determined by the presence of the expected executable.
    if ($App.Type -eq 'zip') {
        $appDir = Join-Path $AppsRoot $App.Name
        $exeRel = $App.Detect.ExeRelativePath
        $exe = if ($exeRel) { Join-Path $appDir $exeRel } else { $null }
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            return [PSCustomObject]@{
                Installed     = $true
                VersionString = (Get-FileVersionSafe -Path $exe)
                Source        = 'zip'
                AppDir        = $appDir
            }
        }
        return [PSCustomObject]@{ Installed = $false; VersionString = $null; Source = 'zip'; AppDir = $appDir }
    }

    # For installer-based apps, prefer a registry lookup as the most reliable detection signal.
    if ($App.Detect -and $App.Detect.MatchNames) {
        $reg = Get-InstalledProgramInfo -MatchNames $App.Detect.MatchNames
        if ($reg) {
            $v = $reg.DisplayVersion
            $loc = Get-InstallLocationFromUninstallEntry -RegEntry $reg
            if (-not $v -and $loc -and $App.Detect.ExeRelativePath) {
                $exe = Join-Path $loc $App.Detect.ExeRelativePath
                $v = Get-FileVersionSafe -Path $exe
            }
            return [PSCustomObject]@{
                Installed     = $true
                VersionString = $v
                Source        = 'registry'
                InstallLocation = $loc
                DisplayName   = $reg.DisplayName
            }
        }
    }

    return [PSCustomObject]@{ Installed = $false; VersionString = $null; Source = 'registry' }
}

function Get-LatestVersionForApp {
    param([Parameter(Mandatory = $true)][hashtable]$App)
    if (-not $App.LatestVersionScript) { return $null }
    try {
        $v = & $App.LatestVersionScript
        return $v
    }
    catch { return $null }
}

# In-memory cache for GitHub Releases API responses.
# Prevents redundant HTTP requests when multiple version
# scripts query the same repository within one run.
$script:_ghCache = @{}

function Get-GitHubRelease {
    param([Parameter(Mandatory)][string]$Repo)
    if ($script:_ghCache.ContainsKey($Repo)) { return $script:_ghCache[$Repo] }
    try {
        $h = @{ 'User-Agent' = 'insta_rig' }
        $j = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $h -ErrorAction Stop
        $script:_ghCache[$Repo] = $j
        return $j
    }
    catch { return $null }
}

$apps = @(

    # ---- Browsers ----
    [ordered]@{
        Name          = 'Brave Browser'
        Url           = 'https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSilentSetup.exe'
        FileName      = 'BraveSetup.exe'
        Type          = 'installer'
        SilentArgs    = ''
        NoInstDir     = $true
        AutoUpdateUrl = $true
        Detect        = @{ MatchNames = @('Brave') }
        LatestVersionScript = {
            $tag = [string](Get-GitHubRelease 'brave/brave-browser').tag_name
            if ($tag -match '([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)') { return $Matches[1] }
            return $null
        }
    },

    # ---- Development ----
    [ordered]@{
        Name       = 'Visual Studio Code'
        Url        = 'https://update.code.visualstudio.com/latest/win32-x64/stable'
        FileName   = 'VSCodeSetup.exe'
        Type       = 'installer'
        SilentArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!runcode /DIR="{INSTDIR}"'
        Detect     = @{ MatchNames = @('Microsoft Visual Studio Code', 'Visual Studio Code') }
        LatestVersionScript = {
            $j = Invoke-RestMethod -Uri 'https://update.code.visualstudio.com/api/update/win32-x64/stable/latest' -ErrorAction Stop
            return $j.productVersion
        }
    },
    [ordered]@{
        Name             = 'Git'
        Url              = ''
        DynamicUrlScript = {
            $j = Get-GitHubRelease 'git-for-windows/git'
            ($j.assets | Where-Object { $_.name -match '64-bit\.exe$' } | Select-Object -First 1).browser_download_url
        }
        FileName   = 'GitSetup.exe'
        Type       = 'installer'
        SilentArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /SP- /DIR="{INSTDIR}"'
        Detect     = @{ MatchNames = @('Git'); ExeRelativePath = 'bin\git.exe' }
        LatestVersionScript = {
            $tag = [string](Get-GitHubRelease 'git-for-windows/git').tag_name
            if ($tag -match '([0-9]+\.[0-9]+\.[0-9]+)') { return $Matches[1] }
            return $null
        }
    },

    # ---- Editors & Viewers ----
    [ordered]@{
        Name             = 'Notepad++'
        Url              = ''
        DynamicUrlScript = {
            $j = Get-GitHubRelease 'notepad-plus-plus/notepad-plus-plus'
            ($j.assets | Where-Object { $_.name -match 'x64\.exe$' -and $_.name -notmatch 'arm' } | Select-Object -First 1).browser_download_url
        }
        FileName   = 'NotepadPlusPlusSetup.exe'
        Type       = 'installer'
        SilentArgs = '/S /D={INSTDIR}'
        Detect     = @{ MatchNames = @('Notepad++'); ExeRelativePath = 'notepad++.exe' }
        LatestVersionScript = {
            $tag = [string](Get-GitHubRelease 'notepad-plus-plus/notepad-plus-plus').tag_name
            if ($tag -match '([0-9]+\.[0-9]+(\.[0-9]+)?)') { return $Matches[1] }
            return $null
        }
    },
    [ordered]@{
        Name             = 'Okular'
        Url              = ''
        DynamicUrlScript = {
            $BaseUrl = 'https://cdn.kde.org/ci-builds/graphics/okular/master/windows/'
            $r = Invoke-WebRequest -Uri $BaseUrl -UseBasicParsing
            $latest = ($r.Links | Where-Object href -match '\.exe$').href | Sort-Object | Select-Object -Last 1
            return $BaseUrl + $latest
        }
        FileName   = 'OkularSetup.exe'
        Type       = 'installer'
        SilentArgs = '/S /D={INSTDIR}'
        NoInstDir  = $false
        Detect     = @{ MatchNames = @('Okular'); ExeRelativePath = 'bin\okular.exe' }
    },

    # ---- Media ----
    [ordered]@{
        Name             = 'VLC Media Player'
        Url              = ''
        DynamicUrlScript = {
            $p = Invoke-WebRequest -Uri 'https://www.videolan.org/vlc/download-windows.html' -UseBasicParsing
            $link = ($p.Links | Where-Object href -match 'win64\.exe$').href | Select-Object -First 1
            if ($link -match '^//') { $link = "https:$link" }
            return $link
        }
        FileName   = 'VLCSetup.exe'
        Type       = 'installer'
        SilentArgs = '/S /D={INSTDIR}'
        Detect     = @{ MatchNames = @('VLC media player', 'VLC'); ExeRelativePath = 'vlc.exe' }
        LatestVersionScript = {
            $p = Invoke-WebRequest -Uri 'https://www.videolan.org/vlc/' -UseBasicParsing
            $m = [regex]::Match($p.Content, 'Version\s+([0-9]+\.[0-9]+\.[0-9]+)')
            if ($m.Success) { return $m.Groups[1].Value }
            $p2 = Invoke-WebRequest -Uri 'https://www.videolan.org/vlc/download-windows.html' -UseBasicParsing
            $m2 = [regex]::Match($p2.Content, 'Version\s+([0-9]+\.[0-9]+\.[0-9]+)')
            if ($m2.Success) { return $m2.Groups[1].Value }
            return $null
        }
    },

    # ---- Utilities ----
    [ordered]@{
        Name             = '7-Zip'
        Url              = ''
        DynamicUrlScript = {
            $j = Get-GitHubRelease 'ip7z/7zip'
            ($j.assets | Where-Object { $_.name -match 'x64\.exe$' } | Select-Object -First 1).browser_download_url
        }
        FileName   = '7zipSetup.exe'
        Type       = 'installer'
        SilentArgs = '/S /D={INSTDIR}'
        Detect     = @{ MatchNames = @('7-Zip'); ExeRelativePath = '7zFM.exe' }
        LatestVersionScript = {
            $tag = [string](Get-GitHubRelease 'ip7z/7zip').tag_name
            if ($tag -match '([0-9]+\.[0-9]+)') { return $Matches[1] }
            return $null
        }
    },
    [ordered]@{
        Name             = 'Bulk Crap Uninstaller'
        Url              = ''
        DynamicUrlScript = {
            $j = Get-GitHubRelease 'Klocman/Bulk-Crap-Uninstaller'
            ($j.assets | Where-Object { $_.name -match '_setup\.exe$' } | Select-Object -Last 1).browser_download_url
        }
        FileName   = 'BCUninstallerSetup.exe'
        Type       = 'installer'
        SilentArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="{INSTDIR}"'
        Detect     = @{ MatchNames = @('Bulk Crap Uninstaller', 'BCUninstaller'); ExeRelativePath = 'BCUninstaller.exe' }
        LatestVersionScript = {
            $tag = [string](Get-GitHubRelease 'Klocman/Bulk-Crap-Uninstaller').tag_name
            if ($tag -match '([0-9]+\.[0-9]+(\.[0-9]+)?)') { return $Matches[1] }
            return $null
        }
    },
    [ordered]@{
        Name       = 'Free Download Manager'
        Url        = 'https://files2.freedownloadmanager.org/6/latest/fdm_x64_setup.exe'
        FileName   = 'FDMSetup.exe'
        Type       = 'installer'
        SilentArgs = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="{INSTDIR}"'
        Detect     = @{ MatchNames = @('Free Download Manager') }
        LatestVersionScript = {
            $p = Invoke-WebRequest -Uri 'https://freedownloadmanager.org/download.htm' -UseBasicParsing
            $m = [regex]::Match($p.Content, 'FDM\s+([0-9]+\.[0-9]+\.[0-9]+)')
            if ($m.Success) { return $m.Groups[1].Value }
            $m2 = [regex]::Match($p.Content, 'Stable\s+release[\s\S]*?FDM\s+([0-9]+\.[0-9]+\.[0-9]+)', 'IgnoreCase')
            if ($m2.Success) { return $m2.Groups[1].Value }
            return $null
        }
    },

    # ---- Communication ----
    [ordered]@{
        Name       = 'Telegram'
        Url        = 'https://telegram.org/dl/desktop/win64_portable'
        FileName   = 'Telegram.zip'
        Type       = 'zip'
        Detect     = @{ ExeRelativePath = 'Telegram.exe' }
        SkipUpdateIfInstalled = $true
    },
    [ordered]@{
        Name       = 'Discord'
        Url        = 'https://discord.com/api/download?platform=win'
        FileName   = 'DiscordSetup.exe'
        Type       = 'installer'
        SilentArgs = '-s'
        NoInstDir  = $true
        Detect     = @{ MatchNames = @('Discord') }
        SkipUpdateIfInstalled = $true
    },

    # ---- Gaming ----
    [ordered]@{
        Name       = 'Steam'
        Url        = 'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe'
        FileName   = 'SteamSetup.exe'
        Type       = 'installer'
        SilentArgs = '/S /D={INSTDIR}'
        Detect     = @{ MatchNames = @('Steam') }
        SkipUpdateIfInstalled = $true
    }
)

# ================================================
# Download Helper
# Downloads a file from the given URL to a local path.
# Uses aria2c (multi-connection) as the primary downloader
# for improved throughput; falls back to Invoke-WebRequest
# (PS 5 / PS 7 compatible) if aria2c is unavailable.
# aria2c is retrieved automatically on first use and cached
# in the TEMP directory for the duration of the session.
# ================================================
function Download-File {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Label
    )

    $aria2 = "$env:TEMP\aria2c.exe"
    $ariaZip = "$env:TEMP\aria2.zip"
    $ariaUrl = 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip'

    # Retrieve and extract aria2c if it is not already present in the TEMP directory.
    if (-not (Test-Path $aria2)) {
        try {
            Invoke-WebRequest -Uri $ariaUrl -OutFile $ariaZip -UseBasicParsing
            $zip = [System.IO.Compression.ZipFile]::OpenRead($ariaZip)
            $entry = $zip.Entries | Where-Object { $_.Name -eq 'aria2c.exe' } | Select-Object -First 1
            if ($entry) {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $aria2, $true)
            }
            $zip.Dispose()
        }
        catch {
            # aria2c could not be retrieved; execution will fall through to the WebRequest downloader.
        }
        finally {
            if (Test-Path $ariaZip) { Remove-Item $ariaZip -Force -ErrorAction SilentlyContinue }
        }
    }

    # Primary download path: aria2c with 16 parallel connections for maximum throughput.
    if (Test-Path $aria2) {
        try {
            if (Test-Path $Destination) { Remove-Item $Destination -Force }
            $dir = Split-Path $Destination
            $file = Split-Path $Destination -Leaf

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $aria2
            $psi.Arguments = "--split=16 --max-connection-per-server=16 --min-split-size=5M " +
            "--console-log-level=warn --summary-interval=1 " +
            "--dir=`"$dir`" --out=`"$file`" `"$Url`""
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true   # Redirect stderr to prevent it from blocking the process
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            # Drain stderr asynchronously to prevent a pipe deadlock when the stderr buffer fills.
            $proc.BeginErrorReadLine()

            while (-not $proc.HasExited) {
                $line = $proc.StandardOutput.ReadLine()
                if (-not $line) { continue }

                if ($line -match '\[#\w+\s+([\d.]+\w+)/([\d.]+\w+)\((\d+)%\).*DL:([\d.]+\w+)') {
                    Show-ProgressBar -Status "Downloading $Label" `
                        -Percent ([int]$Matches[3]) `
                        -Downloaded "$($Matches[1])/$($Matches[2])" `
                        -Speed "$($Matches[4])/s"
                }
                elseif ($line -match '\((\d+)%\)') {
                    Show-ProgressBar -Status "Downloading $Label" -Percent ([int]$Matches[1])
                }
            }
            $proc.WaitForExit()

            if ($proc.ExitCode -eq 0 -and (Test-Path $Destination) -and
                (Get-Item $Destination).Length -gt 0) {
                return $true
            }
            Write-Warn "  aria2c exit code $($proc.ExitCode); using fallback downloader."
        }
        catch {
            Write-Warn "  aria2c failed; using fallback downloader."
        }
        finally {
            Clear-ProgressBar
        }
    }

    # Fallback downloader: Invoke-WebRequest (compatible with both PS 5 and PS 7).
    try {
        Show-ProgressBar -Status "Downloading $Label (fallback)" -Percent -1
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
        if ((Test-Path $Destination) -and (Get-Item $Destination).Length -gt 0) {
            return $true
        }
        return $false
    }
    catch {
        Write-Err "  Download failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        Clear-ProgressBar
    }
}

# ================================================
# Drive / Partition Selection
# Enumerates available file-system drives and prompts
# the user to choose a target drive for the Apps folder.
# ================================================
Write-Info "Choose a drive for Apps folder (e.g. D:\\Apps):"

$drives = @(Get-PSDrive -PSProvider FileSystem |
    Select-Object Name, @{ n = 'FreeGB'; e = { [math]::Round($_.Free / 1GB, 2) } })

for ($i = 0; $i -lt $drives.Count; $i++) {
    Write-Host "  [$($i + 1)] $($drives[$i].Name):  ($($drives[$i].FreeGB) GB free)"
}

$chosenDrive = $null
do {
    $driveInput = Read-Host '  Select a number'
    $driveIdx = 0
    if ([int]::TryParse($driveInput.Trim(), [ref]$driveIdx) -and
        $driveIdx -ge 1 -and $driveIdx -le $drives.Count) {
        $chosenDrive = $drives[$driveIdx - 1].Name
    }
    else {
        Write-Warn '  Invalid choice. Enter a valid number.'
    }
} while (-not $chosenDrive)

$AppsRoot = "$($chosenDrive):\Apps"
if (-not (Test-Path $AppsRoot)) { New-Item -ItemType Directory -Path $AppsRoot -Force | Out-Null }

# ================================================
# Application Selection
# ================================================

# Pre-fetch installation status and latest available versions for the interactive menu.
# Version checks are executed in parallel background jobs (PowerShell 5+) where supported.
Write-Info "`nChecking installed apps..."

$script:_preflightCache = @{}

$useJobs = ($PSVersionTable.PSVersion.Major -ge 5)
$jobList  = [System.Collections.Generic.List[object]]::new()

foreach ($app in $apps) {
    $installedInfo = Get-AppInstalledInfo -App $app -AppsRoot $AppsRoot

    if ($useJobs -and $app.LatestVersionScript) {
        $sb = $app.LatestVersionScript
        $job = Start-Job -ScriptBlock {
            param($block)
            $ProgressPreference = 'SilentlyContinue'  # Suppress progress output inside background jobs
            try { & ([scriptblock]::Create($block)) } catch { $null }
        } -ArgumentList $sb.ToString()
        $jobList.Add([PSCustomObject]@{ App = $app.Name; Job = $job; Installed = $installedInfo })
    }
    else {
        $latest = Get-LatestVersionForApp -App $app
        $script:_preflightCache[$app.Name] = [PSCustomObject]@{
            Installed = $installedInfo
            Latest    = $latest
        }
    }
}

# Collect results from parallel background jobs with a per-job timeout of 15 seconds.
foreach ($entry in $jobList) {
    $latest = $null
    try {
        $latest = $entry.Job | Wait-Job -Timeout 15 | Receive-Job
        $entry.Job | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    catch { }
    $script:_preflightCache[$entry.App] = [PSCustomObject]@{
        Installed = $entry.Installed
        Latest    = $latest
    }
}

# Render the interactive application selection menu.
$winWidth  = $Host.UI.RawUI.WindowSize.Width
$colStatus = 14   # width of status column
$colName   = 26   # width of app name column

Write-Host ''
Write-Host ('  ' + 'NUM'.PadRight(5) + 'STATUS'.PadRight($colStatus) + 'APP'.PadRight($colName) + 'VERSION') -ForegroundColor DarkGray
Write-Host ('  ' + ('-' * ($winWidth - 6))) -ForegroundColor DarkGray

for ($i = 0; $i -lt $apps.Count; $i++) {
    $app    = $apps[$i]
    $pf     = $script:_preflightCache[$app.Name]
    $inst   = $pf.Installed
    $latest = $pf.Latest

    $num = "[$($i + 1)]".PadRight(5)

    # Determine the status label and colour based on installation and version state.
    if (-not $inst.Installed) {
        $statusLabel = 'NOT INSTALLED'
        $statusColor = 'DarkGray'
        $verLabel    = if ($latest) { "latest: $latest" } else { '' }
        $verColor    = 'DarkGray'
    }
    else {
        $instVer   = ConvertTo-VersionSafe -VersionString $inst.VersionString
        $latestVer = ConvertTo-VersionSafe -VersionString $latest

        if ($latestVer -and $instVer -and ($instVer -lt $latestVer)) {
            $statusLabel = 'UPDATE AVAIL'
            $statusColor = 'Yellow'
            $verLabel    = "$($inst.VersionString) -> $latest"
            $verColor    = 'Yellow'
        }
        elseif ($app.SkipUpdateIfInstalled) {
            $statusLabel = 'INSTALLED'
            $statusColor = 'Green'
            $verLabel    = if ($inst.VersionString) { $inst.VersionString } else { '' }
            $verColor    = 'DarkGray'
        }
        else {
            $statusLabel = 'UP TO DATE'
            $statusColor = 'Green'
            $verLabel    = if ($inst.VersionString) { $inst.VersionString } else { '' }
            $verColor    = 'DarkGray'
        }
    }

    $nameCol   = $app.Name.PadRight($colName)
    $statusCol = $statusLabel.PadRight($colStatus)

    Write-Host "  $num" -NoNewline -ForegroundColor DarkGray
    Write-Host $statusCol -NoNewline -ForegroundColor $statusColor
    Write-Host $nameCol   -NoNewline -ForegroundColor White
    Write-Host $verLabel             -ForegroundColor $verColor
}

Write-Host ('  ' + ('-' * ($winWidth - 6))) -ForegroundColor DarkGray
Write-Info '  A = all   U = updates only   1,3,5 = pick by number'
Write-Host ''

$selected = $null
do {
    $choice = (Read-Host '  Your choice').Trim()

    switch ($choice.ToUpper()) {
        'A' {
            $selected = $apps
        }
        'U' {
            $selected = @($apps | Where-Object {
                $pf  = $script:_preflightCache[$_.Name]
                $iv  = ConvertTo-VersionSafe -VersionString $pf.Installed.VersionString
                $lv  = ConvertTo-VersionSafe -VersionString $pf.Latest
                (-not $pf.Installed.Installed) -or ($iv -and $lv -and $iv -lt $lv)
            })
            if (-not $selected) { Write-Warn '  No updates or new installs found.' }
        }
        default {
            $indices = $choice -split ',' |
                ForEach-Object {
                    $n = 0
                    if ([int]::TryParse($_.Trim(), [ref]$n)) { $n }
                } |
                Where-Object { $_ -ge 1 -and $_ -le $apps.Count }

            if ($indices) {
                $selected = @($indices | ForEach-Object { $apps[$_ - 1] })
            }
        }
    }

    if (-not $selected) { Write-Warn '  No valid selection. Try again.' }
} while (-not $selected)

# ================================================
# Download and Installation Loop
# Iterates over the selected applications, resolves
# download URLs, detects existing installations,
# compares versions, then downloads and installs
# each application. Results are collected for the
# summary report.
# ================================================
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($app in $selected) {
    Write-Host "`n[$($app.Name)]" -ForegroundColor White

    # Resolve the dynamic download URL at runtime when a DynamicUrlScript is defined.
    if ($app.DynamicUrlScript) {
        Write-Note "  Resolving latest download URL..."
        try {
            $app.Url = & $app.DynamicUrlScript
            if (-not $app.Url) { throw "Script block returned an empty URL." }
        }
        catch {
            Write-Err "  URL resolve failed: $($_.Exception.Message)"
            $results.Add([PSCustomObject]@{ App = $app.Name; Status = 'FAILED (URL Resolve)' })
            continue
        }
    }

    # Detect the current installation state and compare versions where possible.
    $installedInfo = Get-AppInstalledInfo -App $app -AppsRoot $AppsRoot
    $installedVersion = ConvertTo-VersionSafe -VersionString $installedInfo.VersionString

    $latestVersionString = Get-LatestVersionForApp -App $app
    $latestVersion = ConvertTo-VersionSafe -VersionString $latestVersionString

    if ($installedInfo.Installed) {
        if ($app.SkipUpdateIfInstalled) {
            Write-Ok "  Installed. Skipping."
            $loc = if ($installedInfo.AppDir) { $installedInfo.AppDir } elseif ($installedInfo.InstallLocation) { $installedInfo.InstallLocation } else { '' }
            $results.Add([PSCustomObject]@{ App = $app.Name; Status = 'SKIPPED (Installed)'; Location = $loc })
            continue
        }

        $verLabel = if ($installedInfo.VersionString) { $installedInfo.VersionString } else { 'unknown version' }
        Write-Ok "  Installed: $verLabel"

        if ($latestVersion -and $installedVersion) {
            if ($installedVersion -ge $latestVersion) {
                Write-Ok "  Up to date. Skipping. (latest: $latestVersionString)"
                $loc = if ($installedInfo.AppDir) { $installedInfo.AppDir } elseif ($installedInfo.InstallLocation) { $installedInfo.InstallLocation } else { '' }
                $results.Add([PSCustomObject]@{ App = $app.Name; Status = 'SKIPPED (Up-to-date)'; Location = $loc })
                continue
            }
            else {
                Write-Warn "  Outdated. Updating... (latest: $latestVersionString)"
            }
        }
        elseif ($latestVersionString) {
            Write-Warn "  Updating... (latest: $latestVersionString; local version unknown)"
        }
        else {
            if ($app.AutoUpdateUrl -or $app.DynamicUrlScript) {
                Write-Warn "  Unable to compare version. Updating..."
            }
            else {
                Write-Warn "  Skipping (installed; latest version unknown)."
                $loc = if ($installedInfo.AppDir) { $installedInfo.AppDir } elseif ($installedInfo.InstallLocation) { $installedInfo.InstallLocation } else { '' }
                $results.Add([PSCustomObject]@{ App = $app.Name; Status = 'SKIPPED (Already installed)'; Location = $loc })
                continue
            }
        }
    }

    # Applications flagged as NoInstDir manage their own installation path.
    $appDir = $null
    if ($app.NoInstDir) {
        Write-Note "  Install path: default (custom path not supported)."
    }
    else {
        $appDir = Join-Path $AppsRoot $app.Name
        # Do not pre-create the target folder for installer-type apps; some installers
        # ignore the /DIR argument and create their own directory structure.
        # The folder is only created when required (e.g. for ZIP extraction).
        if ($app.Type -eq 'zip' -and -not (Test-Path $appDir)) {
            New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        }
    }

    $tmpFile = Join-Path $env:TEMP $app.FileName
    if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }

    $downloaded = Download-File -Url $app.Url -Destination $tmpFile -Label $app.Name

    if (-not $downloaded) {
        $results.Add([PSCustomObject]@{ App = $app.Name; Status = 'FAILED (Download)'; Location = '' })
        continue
    }

    $status = 'FAILED (Install)'
    $finalLocation = ''
    try {
        switch ($app.Type) {

            'installer' {
                # Substitute the {INSTDIR} placeholder with the resolved target directory.
                # appDir is $null for NoInstDir applications.
                $resolvedArgs = if ($app.NoInstDir -or -not $appDir) {
                    $app.SilentArgs
                }
                else {
                    $app.SilentArgs -replace '\{INSTDIR\}', $appDir
                }

                try {
                    # Launch the installer process. The script is already running with elevated privileges.
                    $procArgs = @{ FilePath = $tmpFile; PassThru = $true; ErrorAction = 'Stop' }
                    if ($resolvedArgs) { $procArgs['ArgumentList'] = $resolvedArgs }
                    $proc = Start-Process @procArgs

                    # Drive the animated progress bar while the installer process is running.
                    Start-AnimatedBar -Status "Installing $($app.Name)"
                    while (-not $proc.HasExited) {
                        Invoke-AnimationTick
                        Start-Sleep -Milliseconds 30
                    }
                    Start-Sleep -Seconds 2
                    Stop-AnimatedBar

                    $exitOk = ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010)
                    if ($exitOk) {
                        $status = 'SUCCESS'
                        Write-Ok "  Done."

                        # Verify the target directory was populated by the installer.
                        # Avoid recording empty or non-existent folders created by installers
                        # that do not honour the /DIR argument.

                        $post = Get-AppInstalledInfo -App $app -AppsRoot $AppsRoot
                        if ($appDir -and (Test-DirectoryPopulated -Path $appDir)) {
                            $finalLocation = $appDir
                        }
                        elseif ($post.InstallLocation) {
                            $finalLocation = $post.InstallLocation
                        }
                        else {
                            $finalLocation = ''
                        }
                    }
                    else {
                        Write-Err "  Installer exit code: $($proc.ExitCode)"
                    }
                }
                finally { }
            }

            'zip' {
                Write-Note '  Extracting...'

                $stagingDir = Join-Path $env:TEMP "$($app.Name)_extract"
                if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }

                [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpFile, $stagingDir)

                # Flatten a single top-level folder if present (e.g. Telegram Desktop\*),
                # so the application files reside directly under the target directory.
                $topItems = @(Get-ChildItem -LiteralPath $stagingDir)
                if ($topItems.Count -eq 1 -and $topItems[0].PSIsContainer) {
                    Get-ChildItem -LiteralPath $topItems[0].FullName |
                    Move-Item -Destination $appDir -Force
                    Remove-Item $topItems[0].FullName -Recurse -Force
                }
                else {
                    Get-ChildItem -LiteralPath $stagingDir |
                    Move-Item -Destination $appDir -Force
                }
                Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue

                $status = 'SUCCESS'
                Write-Ok '  Done.'
                $finalLocation = $appDir
            }

            default {
                Write-Err "  Unknown app type: $($app.Type)"
            }
        }
    }
    catch {
        Stop-AnimatedBar
        Write-Err "  Error: $($_.Exception.Message)"
    }
    finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }

    if (-not $finalLocation) {
        $post = Get-AppInstalledInfo -App $app -AppsRoot $AppsRoot
        $finalLocation = if ($post.AppDir) { $post.AppDir } elseif ($post.InstallLocation) { $post.InstallLocation } else { '' }
    }

    $results.Add([PSCustomObject]@{ App = $app.Name; Status = $status; Location = $finalLocation })
}

$totalTimer.Stop()

# ================================================
# Installation Summary
# Displays a formatted table of results grouped by
# outcome (SUCCESS / SKIPPED / FAILED), followed by
# aggregate counts and total elapsed time.
# ================================================
$totalTimer.Stop()

$ok      = @($results | Where-Object { $_.Status -eq 'SUCCESS' })
$skipped = @($results | Where-Object { $_.Status -like 'SKIPPED*' })
$failed  = @($results | Where-Object { $_.Status -like 'FAILED*' })

$colStat = 22
$colApp  = 26

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host '              INSTALLATION SUMMARY' -ForegroundColor White
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host ("  " + 'STATUS'.PadRight($colStat) + 'APP'.PadRight($colApp) + 'LOCATION') -ForegroundColor DarkGray
Write-Host ("  " + ('-' * 58)) -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = if     ($r.Status -eq 'SUCCESS')    { 'Green'  }
             elseif ($r.Status -like 'FAILED*')  { 'Red'    }
             else                                { 'Yellow' }

    $loc = if ($r.Location) { $r.Location } else { '-' }

    Write-Host "  " -NoNewline
    Write-Host $r.Status.PadRight($colStat) -NoNewline -ForegroundColor $color
    Write-Host $r.App.PadRight($colApp)     -NoNewline -ForegroundColor White
    Write-Host $loc                                    -ForegroundColor DarkGray
}

Write-Host ("  " + ('-' * 58)) -ForegroundColor DarkGray

$parts = @()
if ($ok.Count)      { $parts += "$($ok.Count) installed/updated" }
if ($skipped.Count) { $parts += "$($skipped.Count) skipped" }
if ($failed.Count)  { $parts += "$($failed.Count) failed" }
Write-Host ("  " + ($parts -join '   .   ')) -ForegroundColor DarkGray

Write-Host ''
Write-Host "  Time:   $($totalTimer.Elapsed.ToString('mm\:ss'))" -ForegroundColor DarkGray
Write-Host "  Folder: $AppsRoot"                                 -ForegroundColor DarkGray
Write-Ok "`nDone."
if ($AutoElevated) {
    Read-Host "`n  Press Enter to close"
}
