# ===================================================
# insta_rig.ps1 - Automated App Installer for Windows
# ===================================================

Clear-Host
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

# ================================================
# Auto-Elevate to Administrator
# ================================================
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    Start-Process $shell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ================================================
# Console Output Helpers
# ================================================
function Write-Info { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Ok { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Note { param([string]$Message) Write-Host $Message -ForegroundColor DarkGray }
function Write-Err { param([string]$Message) Write-Host $Message -ForegroundColor Red }

# ================================================
# Progress Bar
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

# Animated scanner bar for install phases (driven by a timer loop on the main thread)
function Start-AnimatedBar {
    param([string]$Status)

    # Reserve two console lines so the row index stays stable.
    if ($script:_pbRow -lt 0) {
        [Console]::WriteLine()
        [Console]::WriteLine()
        $script:_pbRow = $Host.UI.RawUI.CursorPosition.Y - 2
    }

    $pbRow = $script:_pbRow
    $winWidth = $Host.UI.RawUI.WindowSize.Width
    $barInner = [Math]::Max(10, $winWidth - 3)
    $scanLen = [Math]::Max(6, [int]($barInner * 0.18))   

    # Status line 
    $available = $winWidth - 10
    $line1 = if ($Status.Length -gt $available) { $Status.Substring(0, $available) } else { $Status.PadRight($available) }
    $line1 += ' ...  '.PadLeft(8)

    [Console]::SetCursorPosition(0, $pbRow)
    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::DarkCyan
    [Console]::Write($line1)
    [Console]::ResetColor()

    # Store animation state in script scope so Stop-AnimatedBar can clean up.
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

    # Advance scan position.
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
# App Definitions
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

        # Extract first quoted path, else first token.
        $path = $null
        $m = [regex]::Match($s, '"([^"]+)"')
        if ($m.Success) { $path = $m.Groups[1].Value } else { $path = ($s -split '\s+')[0] }
        $path = $path.Trim()
        if (-not $path) { continue }

        # Strip trailing commas and arguments.
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

    # ZIP apps: treat "installed" as extracted EXE exists.
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

    # Installer apps: registry lookup first (best signal).
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

$apps = @(
    [ordered]@{
        Name       = 'Brave Browser'
        Url        = 'https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSilentSetup.exe'
        FileName   = 'BraveSetup.exe'
        Type       = 'installer'
        SilentArgs = ''
        NoInstDir  = $true
        Detect     = @{ MatchNames = @('Brave') }
        AutoUpdateUrl = $true
        LatestVersionScript = {
            $h = @{ 'User-Agent' = 'insta_rig' }
            $j = Invoke-RestMethod -Uri 'https://api.github.com/repos/brave/brave-browser/releases/latest' -Headers $h -ErrorAction Stop
            $tag = [string]$j.tag_name
            if ($tag -match '([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)') { return $Matches[1] }
            return $null
        }
    },
    [ordered]@{
        Name       = 'Visual Studio Code'
        Url        = 'https://update.code.visualstudio.com/latest/win32-x64/stable'
        FileName   = 'VSCodeSetup.exe'
        Type       = 'installer'
        SilentArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!runcode /DIR="{INSTDIR}"'
        Detect     = @{ MatchNames = @('Microsoft Visual Studio Code', 'Visual Studio Code') }
        LatestVersionScript = {
            $u = 'https://update.code.visualstudio.com/api/update/win32-x64/stable/latest'
            $j = Invoke-RestMethod -Uri $u -ErrorAction Stop
            return $j.productVersion
        }
    },
    [ordered]@{
        Name     = 'Telegram'
        Url      = 'https://telegram.org/dl/desktop/win64_portable'
        FileName = 'Telegram.zip'
        Type     = 'zip'
        Detect   = @{ ExeRelativePath = 'Telegram.exe' }
        LatestVersionScript = {
            $h = @{ 'User-Agent' = 'insta_rig' }
            $j = Invoke-RestMethod -Uri 'https://api.github.com/repos/telegramdesktop/tdesktop/releases/latest' -Headers $h -ErrorAction Stop
            $tag = [string]$j.tag_name
            if ($tag -match '([0-9]+\.[0-9]+(\.[0-9]+)?)') { return $Matches[1] }
            return $null
        }
    },
    [ordered]@{
        Name             = 'VLC Media Player'
        Url              = ''
        DynamicUrlScript = {
            $DownloadPage = Invoke-WebRequest -Uri 'https://www.videolan.org/vlc/download-windows.html' -UseBasicParsing
            $LatestLink = ($DownloadPage.Links | Where-Object href -match 'win64\.exe$').href | Select-Object -First 1

            if ($LatestLink -match '^//') {
                $LatestLink = "https:$LatestLink"
            }
            
            return $LatestLink
        }
        FileName         = 'VLCSetup.exe'
        Type             = 'installer'
        SilentArgs       = '/S /D={INSTDIR}'
        Detect           = @{ MatchNames = @('VLC media player', 'VLC'); ExeRelativePath = 'vlc.exe' }
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
    [ordered]@{
        Name       = 'Free Download Manager'
        Url        = 'https://files2.freedownloadmanager.org/6/latest/fdm_x64_setup.exe'
        FileName   = 'FDMSetup.exe'
        Type       = 'installer'
        SilentArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="{INSTDIR}"'
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
    [ordered]@{
        Name       = 'Steam'
        Url        = 'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe'
        FileName   = 'SteamSetup.exe'
        Type       = 'installer'
        SilentArgs = '/S /D={INSTDIR}'
        Detect     = @{ MatchNames = @('Steam') }
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
    [ordered]@{
        Name             = 'Okular'
        Url              = '' 
        DynamicUrlScript = {
            $BaseUrl = 'https://cdn.kde.org/ci-builds/graphics/okular/master/windows/'
            $WebResponse = Invoke-WebRequest -Uri $BaseUrl -UseBasicParsing
            $LatestExe = ($WebResponse.Links | Where-Object href -match '\.exe$').href | Sort-Object | Select-Object -Last 1
            return $BaseUrl + $LatestExe
        }
        FileName         = 'OkularSetup.exe'
        Type             = 'installer'
        SilentArgs       = '/S /D={INSTDIR}'
        NoInstDir        = $false 
        Detect           = @{ MatchNames = @('Okular'); ExeRelativePath = 'bin\okular.exe' }
    }
)

# ================================================
# Download Helper  (aria2c with WebRequest fallback)
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

    # --- Try to obtain aria2c if not already cached ---
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
            # aria2 unavailable; will fall through to WebRequest
        }
        finally {
            if (Test-Path $ariaZip) { Remove-Item $ariaZip -Force -ErrorAction SilentlyContinue }
        }
    }

    # --- Download with aria2c ---
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
            $psi.RedirectStandardError = $true   # prevent stderr from blocking the process
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            # Drain stderr asynchronously to avoid deadlock
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

    # --- Fallback: Invoke-WebRequest (works on PS5 and PS7) ---
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
# App Selection
# ================================================
Write-Info "`nSelect apps (e.g. 1,3 or A for all):"
for ($i = 0; $i -lt $apps.Count; $i++) {
    Write-Host "  [$($i + 1)] $($apps[$i].Name)"
}

$selected = $null
do {
    $choice = (Read-Host '  Your choice').Trim()

    if ($choice.ToUpper() -eq 'A') {
        $selected = $apps
    }
    else {
        # Parse comma-separated integers, validate each, collect matching apps
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

    if (-not $selected) {
        Write-Warn '  No valid selection. Try again.'
    }
} while (-not $selected)

# ================================================
# Download & Install Loop
# ================================================
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($app in $selected) {
    Write-Host "`n[$($app.Name)]" -ForegroundColor White

    # Resolve dynamic download URL, when provided.
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

    # Detect installation and, where possible, compare versions.
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

    # NoInstDir apps manage their own install location.
    $appDir = $null
    if ($app.NoInstDir) {
        Write-Note "  Install path: default (custom path not supported)."
    }
    else {
        $appDir = Join-Path $AppsRoot $app.Name
        # Don't pre-create folders for installers (some ignore /DIR).
        # Create the folder only when required (ZIP extraction).
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
                # Substitute {INSTDIR} placeholder; appDir is $null for NoInstDir apps
                $resolvedArgs = if ($app.NoInstDir -or -not $appDir) {
                    $app.SilentArgs
                }
                else {
                    $app.SilentArgs -replace '\{INSTDIR\}', $appDir
                }

                # Launch installer (already elevated).
                $procArgs = @{ FilePath = $tmpFile; PassThru = $true; ErrorAction = 'Stop' }
                if ($resolvedArgs) { $procArgs['ArgumentList'] = $resolvedArgs }
                $proc = Start-Process @procArgs

                # Animate while installer runs
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

                    # If installer supported custom dir, it should have created it.
                    # Avoid creating empty folders when installers ignore /DIR.

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

            'zip' {
                Write-Note '  Extracting...'

                $stagingDir = Join-Path $env:TEMP "$($app.Name)_extract"
                if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }

                [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpFile, $stagingDir)

                # Flatten single top-level folder (e.g. Telegram Desktop\*)
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
# Summary
# ================================================
Write-Host ("`n" + ('=' * 60)) -ForegroundColor DarkGray
Write-Host '                    INSTALLATION SUMMARY'   -ForegroundColor White
Write-Host ('=' * 60)                                   -ForegroundColor DarkGray

foreach ($r in $results) {
    $color =
    if ($r.Status -eq 'SUCCESS') { 'Green' }
    elseif ($r.Status -like 'FAILED*') { 'Red' }
    else { 'Yellow' }

    $loc = if ($r.Location) { $r.Location } else { '-' }
    Write-Host "  $($r.Status.PadRight(30)) $($r.App)" -ForegroundColor $color -NoNewline
    Write-Host "  [$loc]" -ForegroundColor DarkGray
}

Write-Host "`nTotal time: $($totalTimer.Elapsed.ToString('mm\:ss'))" -ForegroundColor DarkGray
Write-Host "Apps folder: $AppsRoot" -ForegroundColor DarkGray
Write-Ok "`nDone."
