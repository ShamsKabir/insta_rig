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
    $wt = Get-Command wt -ErrorAction SilentlyContinue
    # Pass -AutoElevated so the relaunched elevated session knows to pause at the end.
    $relaunchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -AutoElevated"
    if ($wt) {
        # Open a brand-new, separate Windows Terminal window using '-w new'.
        # The elevated session is fully independent — no shared window lifetime.
        Start-Process wt -Verb RunAs -ArgumentList "-w new $shell $relaunchArgs"
    }
    else {
        # No Windows Terminal available; launch the shell directly in a new elevated window.
        Start-Process $shell -Verb RunAs -ArgumentList $relaunchArgs
    }
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
    $bar = ([char]0x2588 -as [string]) * $filled + ([char]0x2591 -as [string]) * $empty

    if ($script:_pbRow -lt 0) {
        [Console]::CursorVisible = $false
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
    [Console]::CursorVisible = $true
}

# Animated scanner bar for install phases (driven by a timer-based tick loop on the main thread).
function Start-AnimatedBar {
    param([string]$Status)

    # Reserve two console lines so the row index remains stable across redraws.
    if ($script:_pbRow -lt 0) {
        [Console]::CursorVisible = $false
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

    # Fast string-multiply approach — no char array allocation or -join overhead
    $clampedPos = [Math]::Max(0, $pos)
    $clampedEnd = [Math]::Min($inner, $pos + $scanLen)
    $filledCount = [Math]::Max(0, $clampedEnd - $clampedPos)
    $bar = ([char]0x2591 -as [string]) * $clampedPos +
    ([char]0x2588 -as [string]) * $filledCount +
    ([char]0x2591 -as [string]) * ($inner - $clampedPos - $filledCount)

    [Console]::SetCursorPosition(0, $script:_animPbRow + 1)
    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::Blue
    [Console]::Write($bar)
    [Console]::ResetColor()

    # Advance the scanner position; wrap back to the start when the bar end is reached.
    $script:_animPos += 1
    if ($script:_animPos -ge $inner) { $script:_animPos = - $scanLen }
}

function Stop-AnimatedBar {
    if ($script:_animTimer) {
        $script:_animTimer.Stop()
        $script:_animTimer = $null
    }
    Clear-ProgressBar
}

function Start-Spinner {
    param([string]$Status)
    [Console]::CursorVisible = $false
    $script:_spinStatus = $Status
    $script:_spinFrame = 0
    $script:_spinLastMs = 0
    $script:_spinChars = @('|', '/', '-', '\')
    $script:_spinTimer = [System.Diagnostics.Stopwatch]::StartNew()
    [Console]::WriteLine()
    $script:_spinRow = $Host.UI.RawUI.CursorPosition.Y - 1
}

function Invoke-SpinnerTick {
    if (-not $script:_spinTimer) { return }
    $now = $script:_spinTimer.ElapsedMilliseconds
    if (($now - $script:_spinLastMs) -lt 80) { return }
    $script:_spinLastMs = $now
    $c = $script:_spinChars[$script:_spinFrame % 4]
    $script:_spinFrame++
    [Console]::SetCursorPosition(0, $script:_spinRow)
    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::Cyan
    $winWidth = $Host.UI.RawUI.WindowSize.Width
    $padded = $script:_spinStatus.PadRight($winWidth - 2) + $c
    [Console]::Write($padded)
    [Console]::ResetColor()
}

function Stop-Spinner {
    if ($script:_spinTimer) { $script:_spinTimer.Stop(); $script:_spinTimer = $null }
    if ($script:_spinRow -ge 0) {
        $blank = ' ' * ($Host.UI.RawUI.WindowSize.Width - 1)
        [Console]::CursorVisible = $true
        [Console]::SetCursorPosition(0, $script:_spinRow)
        [Console]::Write($blank)
        [Console]::SetCursorPosition(0, $script:_spinRow)
        $script:_spinRow = -1
    }
}

# ================================================
# ASCII Banner
# Renders the application title in two-tone ASCII art
# using Blue and DarkYellow to visually split the text.
# ================================================
Write-Host ''
$lines = @(
    '_________ _      . _______ _________ _______    _______  _________ _______',
    '\__   __/| \    /|(  ____ \\__   __/(  ___  )  (  ___  ) \__   __/(  ____ \',
    '   ) (   |  \  ( || (    \/   ) (   | (   ) |  | (   ) |    ) (   | (    \/',
    '   | |   |   \ | || (_____    | |   | (___) |  | (___) |    | |   | |       ',
    '   | |   | |\ \) |(_____  )   | |   |  ___  |  |     __)    | |   | | ____ ',
    '   | |   | | \   |      ) |   | |   | (   ) |  | (\ (       | |   | | \_  )',
    '___) (___| )  \  |/\____) |   | |   | )   ( |  | ) \ \__ ___) (___| (___) |',
    '\_______/|/    \_|\_______)   )_(   |/     \|  |/   \__/ \_______/(_______)'
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
# Optional keys: Detect, NoInstDir, AutoUpdateUrl.
# ================================================
$script:UninstallRegPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# Lazily-populated cache of all installed programs read from registry.
# Populated on first call; subsequent calls reuse the same list.
$script:_regCache = $null

function Get-AllInstalledPrograms {
    if ($null -ne $script:_regCache) { return $script:_regCache }
    $script:_regCache = foreach ($p in $script:UninstallRegPaths) {
        Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.UninstallString }
    }
    return $script:_regCache
}

function Get-InstalledProgramInfo {
    param(
        [Parameter(Mandatory = $true)][string[]]$MatchNames
    )

    $items = Get-AllInstalledPrograms

    foreach ($name in $MatchNames) {
        # Iterate directly — avoids a second pipeline pass per name
        foreach ($item in $items) {
            if ($item.DisplayName -like "*$name*") {
                return [PSCustomObject]@{
                    DisplayName     = $item.DisplayName
                    DisplayVersion  = $item.DisplayVersion
                    InstallLocation = $item.InstallLocation
                    Publisher       = $item.Publisher
                    UninstallString = $item.UninstallString
                    DisplayIcon     = $item.DisplayIcon
                }
            }
        }
    }
    return $null
}

function Get-InstallLocationFromUninstallEntry {
    param([pscustomobject]$RegEntry)
    if (-not $RegEntry) { return '' }

    # Prefer the InstallLocation registry value when it points to an existing directory.
    if ($RegEntry.InstallLocation -and (Test-Path -LiteralPath $RegEntry.InstallLocation)) {
        return $RegEntry.InstallLocation
    }

    # Fall back to deriving the folder from DisplayIcon or UninstallString executable paths.
    $candidates = @($RegEntry.DisplayIcon, $RegEntry.UninstallString) | Where-Object { $_ }
    foreach ($c in $candidates) {
        $s = [string]$c
        if (-not $s) { continue }

        # Extract the first quoted path; fall back to the first whitespace-delimited token.
        $path = $null
        $m = [regex]::Match($s, '"([^"]+)"')
        if ($m.Success) { $path = $m.Groups[1].Value } else { $path = ($s -split '\s+')[0] }
        $path = $path.Trim().TrimEnd(',')
        if (-not $path) { continue }

        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($item -and -not $item.PSIsContainer) { return (Split-Path -Parent $path) }
            if ($item -and $item.PSIsContainer) { return $path }
        }

        # For apps like Discord that install under a versioned subdirectory (e.g. app-1.0.9043),
        # walk up the tree until we find a populated non-system parent folder.
        $parent = Split-Path -Parent $path
        while ($parent -and $parent.Length -gt 3) {
            if (Test-Path -LiteralPath $parent) {
                $item = Get-Item -LiteralPath $parent -ErrorAction SilentlyContinue
                if ($item -and $item.PSIsContainer) { return $parent }
            }
            $parent = Split-Path -Parent $parent
        }
    }

    return ''
}

function Test-DirectoryPopulated {
    param([string]$Path)
    try {
        if (-not $Path) { return $false }
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        # Use enumerator with -First 1 to short-circuit on the first item found
        $null -ne (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Select-Object -First 1)
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
                Installed       = $true
                VersionString   = $v
                Source          = 'registry'
                InstallLocation = $loc
                DisplayName     = $reg.DisplayName
            }
        }
    }

    return [PSCustomObject]@{ Installed = $false; VersionString = $null; Source = 'registry' }
}


# In-memory cache for GitHub Releases API responses.
# Prevents redundant HTTP requests when multiple DynamicUrlScripts
# query the same repository within one run.
$script:_ghCache = @{}

function Get-GitHubRelease {
    param([Parameter(Mandatory)][string]$Repo)
    if ($script:_ghCache.ContainsKey($Repo)) { return $script:_ghCache[$Repo] }
    try {
        $h = @{ 'User-Agent' = 'insta_rig' }
        $j = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $h -TimeoutSec 6 -ErrorAction Stop
        $script:_ghCache[$Repo] = $j
        return $j
    }
    catch { return $null }
}

$apps = @(

    # ---- Browsers ----
    [ordered]@{
        Name                = 'Brave Browser'
        Url                 = 'https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSilentSetup.exe'
        FileName            = 'BraveSetup.exe'
        Type                = 'installer'
        SilentArgs          = ''
        NoInstDir           = $true
        AutoUpdateUrl       = $true
        Detect              = @{ MatchNames = @('Brave') }
    },

    # ---- Development ----
    [ordered]@{
        Name                = 'Visual Studio Code'
        Url                 = 'https://update.code.visualstudio.com/latest/win32-x64/stable'
        FileName            = 'VSCodeSetup.exe'
        Type                = 'installer'
        SilentArgs          = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!runcode /DIR="{INSTDIR}"'
        Detect              = @{ MatchNames = @('Microsoft Visual Studio Code', 'Visual Studio Code') }
    },
    [ordered]@{
        Name                = 'Git'
        Url                 = ''
        DynamicUrlScript    = {
            $j = Get-GitHubRelease 'git-for-windows/git'
            ($j.assets | Where-Object { $_.name -match '64-bit\.exe$' } | Select-Object -First 1).browser_download_url
        }
        FileName            = 'GitSetup.exe'
        Type                = 'installer'
        SilentArgs          = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /SP- /DIR="{INSTDIR}"'
        Detect              = @{ MatchNames = @('Git'); ExeRelativePath = 'bin\git.exe' }
    },

    # ---- Editors & Viewers ----
    [ordered]@{
        Name                = 'Notepad++'
        Url                 = ''
        DynamicUrlScript    = {
            $j = Get-GitHubRelease 'notepad-plus-plus/notepad-plus-plus'
            ($j.assets | Where-Object { $_.name -match 'x64\.exe$' -and $_.name -notmatch 'arm' } | Select-Object -First 1).browser_download_url
        }
        FileName            = 'NotepadPlusPlusSetup.exe'
        Type                = 'installer'
        SilentArgs          = '/S /D={INSTDIR}'
        Detect              = @{ MatchNames = @('Notepad++'); ExeRelativePath = 'notepad++.exe' }
    },
    [ordered]@{
        Name                = 'Okular'
        Url                 = ''
        DynamicUrlScript    = {
            # Resolve the latest Okular installer from the KDE CI build server.
            $baseUrl = 'https://cdn.kde.org/ci-builds/graphics/okular/master/windows/'
            $r = Invoke-WebRequest -Uri $baseUrl -UseBasicParsing -TimeoutSec 6
            $latest = ($r.Links | Where-Object href -match '\.exe$').href | Sort-Object | Select-Object -Last 1
            return $baseUrl + $latest
        }
        FileName            = 'OkularSetup.exe'
        Type                = 'installer'
        SilentArgs          = '/S /D={INSTDIR}'
        NoInstDir           = $false
        Detect              = @{ MatchNames = @('Okular'); ExeRelativePath = 'bin\okular.exe' }
    },

    # ---- Media ----
    [ordered]@{
        Name                = 'VLC Media Player'
        Url                 = ''
        DynamicUrlScript    = {
            # Resolve the Win64 installer URL from the VideoLAN download page.
            $p = Invoke-WebRequest -Uri 'https://www.videolan.org/vlc/download-windows.html' -UseBasicParsing -TimeoutSec 6
            $link = ($p.Links | Where-Object href -match 'win64\.exe$').href | Select-Object -First 1
            if ($link -match '^//') { $link = "https:$link" }
            return $link
        }
        FileName            = 'VLCSetup.exe'
        Type                = 'installer'
        SilentArgs          = '/S /D={INSTDIR}'
        Detect              = @{ MatchNames = @('VLC media player', 'VLC'); ExeRelativePath = 'vlc.exe' }
    },

    # ---- Utilities ----
    [ordered]@{
        Name                = '7-Zip'
        Url                 = ''
        DynamicUrlScript    = {
            $j = Get-GitHubRelease 'ip7z/7zip'
            ($j.assets | Where-Object { $_.name -match 'x64\.exe$' } | Select-Object -First 1).browser_download_url
        }
        FileName            = '7zipSetup.exe'
        Type                = 'installer'
        SilentArgs          = '/S /D={INSTDIR}'
        Detect              = @{ MatchNames = @('7-Zip'); ExeRelativePath = '7zFM.exe' }
    },
    [ordered]@{
        Name                = 'Bulk Crap Uninstaller'
        Url                 = ''
        DynamicUrlScript    = {
            $j = Get-GitHubRelease 'Klocman/Bulk-Crap-Uninstaller'
            ($j.assets | Where-Object { $_.name -match '_setup\.exe$' } | Select-Object -Last 1).browser_download_url
        }
        FileName            = 'BCUninstallerSetup.exe'
        Type                = 'installer'
        SilentArgs          = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="{INSTDIR}"'
        Detect              = @{ MatchNames = @('Bulk Crap Uninstaller', 'BCUninstaller'); ExeRelativePath = 'BCUninstaller.exe' }
    },
    [ordered]@{
        Name                = 'Free Download Manager'
        Url                 = 'https://files2.freedownloadmanager.org/6/latest/fdm_x64_setup.exe'
        FileName            = 'FDMSetup.exe'
        Type                = 'installer'
        SilentArgs          = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="{INSTDIR}"'
        Detect              = @{ MatchNames = @('Free Download Manager') }
    },

    # ---- Communication ----
    [ordered]@{
        Name                  = 'Telegram'
        Url                   = 'https://github.com/telegramdesktop/tdesktop/releases/download/v6.8.2/tsetup-x64.6.8.2.exe'
        FileName              = 'Telegram.exe'
        Type                  = 'installer'
        SilentArgs            = '/VERYSILENT /NOLAUNCH'
        Detect                = @{ MatchNames = @('Telegram Desktop'); ExeRelativePath = 'Telegram.exe' }
    },
    [ordered]@{
        Name                  = 'Discord'
        Url                   = 'https://discord.com/api/download?platform=win'
        FileName              = 'DiscordSetup.exe'
        Type                  = 'installer'
        SilentArgs            = '-s'
        NoInstDir             = $true
        Detect                = @{ MatchNames = @('Discord') }
    },

    # ---- Gaming ----
    [ordered]@{
        Name                  = 'Steam'
        Url                   = 'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe'
        FileName              = 'SteamSetup.exe'
        Type                  = 'installer'
        SilentArgs            = '/S /D={INSTDIR}'
        Detect                = @{ MatchNames = @('Steam') }
    }
)

# ================================================
# Recommended App Set
# Defines the subset of apps installed when the user
# selects the (R) Recommended option.
# ================================================
$recommendedAppNames = @(
    'Visual Studio Code',
    'Free Download Manager',
    'Brave Browser',
    'Git',
    'VLC Media Player',
    '7-Zip'
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
            $psi.RedirectStandardError = $true   # Redirect stderr to prevent pipe deadlock.
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            # Drain stderr asynchronously to prevent a pipe deadlock when the buffer fills.
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
Write-Info "Choose a drive for Apps folder (e.g. D:\Apps):"

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
# Checks installation status for all apps before
# rendering the interactive menu.
# ================================================

# Show a spinner while checking installed apps.
Start-Spinner -Status 'Checking installed apps...'

$script:_preflightCache = @{}

foreach ($app in $apps) {
    $script:_preflightCache[$app.Name] = Get-AppInstalledInfo -App $app -AppsRoot $AppsRoot
    Invoke-SpinnerTick
}

Stop-Spinner

# ------------------------------------------------
# Render the interactive application selection menu.
# ------------------------------------------------
$winWidth = $Host.UI.RawUI.WindowSize.Width
$colStatus = 14   # width of status column
$colName = 26   # width of app name column

Write-Host ''
Write-Host ('  ' + 'NUM'.PadRight(5) + 'STATUS'.PadRight($colStatus) + 'APP'.PadRight($colName) + 'VERSION') -ForegroundColor DarkGray
Write-Host ('  ' + ('-' * ($winWidth - 6))) -ForegroundColor DarkGray

for ($i = 0; $i -lt $apps.Count; $i++) {
    $app = $apps[$i]
    $inst = $script:_preflightCache[$app.Name]

    $num = "[$($i + 1)]".PadRight(5)

    if (-not $inst.Installed) {
        $statusLabel = 'NOT INSTALLED'
        $statusColor = 'DarkGray'
        $verLabel    = ''
    }
    else {
        $statusLabel = 'INSTALLED'
        $statusColor = 'Green'
        $verLabel    = if ($inst.VersionString) { $inst.VersionString } else { '' }
    }

    # Mark recommended apps with a star indicator.
    $recMark = if ($recommendedAppNames -contains $app.Name) { '*' } else { ' ' }
    $nameCol = ($recMark + $app.Name).PadRight($colName)
    $statusCol = $statusLabel.PadRight($colStatus)

    Write-Host "  $num" -NoNewline -ForegroundColor DarkGray
    Write-Host $statusCol -NoNewline -ForegroundColor $statusColor
    Write-Host $nameCol   -NoNewline -ForegroundColor White
    Write-Host $verLabel             -ForegroundColor DarkGray
}

Write-Host ('  ' + ('-' * ($winWidth - 6))) -ForegroundColor DarkGray
Write-Host '  * = included in Recommended set' -ForegroundColor DarkGray
Write-Info '  A = all   R = recommended   1,3,5 = pick by number'
Write-Host ''

$selected = $null
do {
    $choice = (Read-Host '  Your choice').Trim()

    switch ($choice.ToUpper()) {
        'A' {
            $selected = $apps
        }
        'R' {
            # Install the predefined recommended set.
            $selected = @($apps | Where-Object { $recommendedAppNames -contains $_.Name })
            if (-not $selected) { Write-Warn '  No recommended apps found in the list.' }
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
# then downloads and installs each application.
# Results are collected for the summary report.
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
            $results.Add([PSCustomObject]@{ App = $app.Name; Status = 'FAILED (URL Resolve)'; Location = '' })
            continue
        }
    }

    # Detect the current installation state — reuse preflight cache when available.
    $installedInfo = if ($script:_preflightCache.ContainsKey($app.Name)) {
        $script:_preflightCache[$app.Name]
    } else {
        Get-AppInstalledInfo -App $app -AppsRoot $AppsRoot
    }

    if ($installedInfo.Installed) {
        Write-Ok "  Already installed. Skipping."
        $loc = if ($installedInfo.AppDir) { $installedInfo.AppDir }
        elseif ($installedInfo.InstallLocation) { $installedInfo.InstallLocation }
        elseif ($app.Detect -and $app.Detect.MatchNames) {
            $reg = Get-InstalledProgramInfo -MatchNames $app.Detect.MatchNames
            if ($reg) { Get-InstallLocationFromUninstallEntry -RegEntry $reg } else { '' }
        }
        else { '' }
        $results.Add([PSCustomObject]@{ App = $app.Name; Status = 'SKIPPED (Installed)'; Location = $loc })
        continue
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
                    elseif ($app.Detect -and $app.Detect.MatchNames) {
                        # For NoInstDir apps (e.g. Discord) the installer picks its own path.
                        # Re-query the registry after install to surface the actual location.
                        $reg = Get-InstalledProgramInfo -MatchNames $app.Detect.MatchNames
                        $finalLocation = if ($reg) { Get-InstallLocationFromUninstallEntry -RegEntry $reg } else { '' }
                    }
                    else {
                        $finalLocation = ''
                    }
                }
                else {
                    Write-Err "  Installer exit code: $($proc.ExitCode)"
                }
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
                $finalLocation = $appDir
                Write-Ok '  Done.'
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

    # Last-resort location resolution: re-read the registry if still empty after install.
    if (-not $finalLocation) {
        $post = Get-AppInstalledInfo -App $app -AppsRoot $AppsRoot
        $finalLocation = if ($post.AppDir) { $post.AppDir }
        elseif ($post.InstallLocation) { $post.InstallLocation }
        elseif ($app.Detect -and $app.Detect.MatchNames) {
            $reg = Get-InstalledProgramInfo -MatchNames $app.Detect.MatchNames
            if ($reg) { Get-InstallLocationFromUninstallEntry -RegEntry $reg } else { '' }
        }
        else { '' }
    }

    $results.Add([PSCustomObject]@{ App = $app.Name; Status = $status; Location = $finalLocation })
}

$totalTimer.Stop()

# ================================================
# Startup Applications — Optional Disable
# Prompts the user before removing auto-start entries
# for apps known to register themselves at boot. Covers:
#   - HKCU Run key (current user auto-start)
#   - HKLM Run key (all users auto-start)
#   - Task Manager startup approved list
#     (HKCU\...\StartupApproved\Run)
# Apps targeted: Discord, Steam, Free Download Manager.
# Extend $startupAppPatterns to cover additional apps.
# ================================================
Write-Host ''
$startupChoice = Read-Host '  Disable startup entries for installed apps? (Y/N)'

if ($startupChoice.Trim().ToUpper() -eq 'Y') {

    Write-Host '  Disabling startup entries...' -ForegroundColor Cyan

    $startupAppPatterns = @(
        'Discord',
        'Steam',
        'Free Download Manager',
        'FDM'
    )

    $runPaths = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )

    $approvedPaths = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'
    )

    $disabledCount = 0

    foreach ($runPath in $runPaths) {
        if (-not (Test-Path $runPath)) { continue }
        $props = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $patternRegex = ($startupAppPatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
        foreach ($name in ($props.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -and $_.Name -notlike 'PS*' }).Name) {
            if ($name -match $patternRegex) {
                try {
                    Remove-ItemProperty -Path $runPath -Name $name -ErrorAction Stop
                    Write-Host "    Removed Run key: '$name' from $runPath" -ForegroundColor DarkGray
                    $disabledCount++
                }
                catch {
                    Write-Host "    Could not remove '$name': $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
    }

    # Stamp the StartupApproved bytes to the disabled state (03 00 00 00 00 00 00 00 00 00 00 00)
    # so Task Manager shows the entry as Disabled even if the Run key is re-added by the app.
    $disabledBytes = [byte[]](0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)

    foreach ($approvedPath in $approvedPaths) {
        if (-not (Test-Path $approvedPath)) { continue }
        $props = Get-ItemProperty -Path $approvedPath -ErrorAction SilentlyContinue
        if (-not $props) { continue }
        $patternRegex = ($startupAppPatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
        foreach ($name in ($props.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' -and $_.Name -notlike 'PS*' }).Name) {
            if ($name -match $patternRegex) {
                try {
                    Set-ItemProperty -Path $approvedPath -Name $name -Value $disabledBytes -Type Binary -ErrorAction Stop
                    Write-Host "    Disabled StartupApproved: '$name'" -ForegroundColor DarkGray
                    $disabledCount++
                }
                catch {
                    Write-Host "    Could not disable '$name': $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
    }

    if ($disabledCount -eq 0) {
        Write-Host '    No matching startup entries found (they may not be registered yet).' -ForegroundColor DarkGray
    }
    else {
        Write-Ok "    $disabledCount startup entry/entries disabled."
    }

}
else {
    Write-Note '  Startup entries left unchanged.'
}

# ================================================
# Installation Summary
# Displays a formatted table of results grouped by
# outcome (SUCCESS / SKIPPED / FAILED), followed by
# aggregate counts and total elapsed time.
# ================================================
$ok = @($results | Where-Object { $_.Status -eq 'SUCCESS' })
$skipped = @($results | Where-Object { $_.Status -like 'SKIPPED*' })
$failed = @($results | Where-Object { $_.Status -like 'FAILED*' })

$colStat = 22
$colApp = 26

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host '              INSTALLATION SUMMARY' -ForegroundColor White
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host ("  " + 'STATUS'.PadRight($colStat) + 'APP'.PadRight($colApp) + 'LOCATION') -ForegroundColor DarkGray
Write-Host ("  " + ('-' * 58)) -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = if ($r.Status -eq 'SUCCESS') { 'Green' }
    elseif ($r.Status -like 'FAILED*') { 'Red' }
    else { 'Yellow' }

    $loc = if ($r.Location) { $r.Location } else { '-' }

    Write-Host "  " -NoNewline
    Write-Host $r.Status.PadRight($colStat) -NoNewline -ForegroundColor $color
    Write-Host $r.App.PadRight($colApp)     -NoNewline -ForegroundColor White
    Write-Host $loc                                    -ForegroundColor DarkGray
}

Write-Host ("  " + ('-' * 58)) -ForegroundColor DarkGray

$parts = @()
if ($ok.Count) { $parts += "$($ok.Count) installed" }
if ($skipped.Count) { $parts += "$($skipped.Count) skipped" }
if ($failed.Count) { $parts += "$($failed.Count) failed" }
Write-Host ("  " + ($parts -join '   .   ')) -ForegroundColor DarkGray

Write-Host ''
Write-Host "  Time:   $($totalTimer.Elapsed.ToString('mm\:ss'))" -ForegroundColor DarkGray
Write-Host "  Folder: $AppsRoot"                                 -ForegroundColor DarkGray
Write-Ok "`nDone."

if ($AutoElevated) {
    Read-Host "`n  Press Enter to close"
}
