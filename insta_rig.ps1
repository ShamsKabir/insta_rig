# ===================================================
# auto_win.ps1 - Automated App Installer for Windows
# ===================================================

Clear-Host

$ProgressPreference = 'SilentlyContinue'

# Auto-Elevate
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Start-Process $shell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ================================================
# Progress Bar
# ================================================
$script:_pbRow = -1

function Show-ProgressBar {
    param(
        [string]$Status,
        [int]$Percent = -1,
        [string]$Downloaded = "",
        [string]$Speed = ""
    )

    $winWidth = $Host.UI.RawUI.WindowSize.Width

    $stats = ""
    if ($Downloaded) { $stats += $Downloaded }
    if ($Speed)      { $stats += " @ $Speed" }
    $stats = $stats.Trim()

    $pctLabel = if ($Percent -lt 0) { '  --  ' } else { "$Percent%" }

    $statusPart = $Status
    if ($stats) { $statusPart = "$Status  $stats" }

    $available = $winWidth - 10
    $line1 = if ($statusPart.Length -gt $available) {
        $statusPart.Substring(0, $available)
    } else {
        $statusPart.PadRight($available)
    }
    $line1 += $pctLabel.PadLeft(8)

    $barInner = [Math]::Max(10, $winWidth - 3)
    $indeterminate = $Percent -lt 0
    $filled = if ($indeterminate) { $barInner } else { [Math]::Min($barInner, [int](($barInner * $Percent) / 100)) }
    $empty  = $barInner - $filled
    $bar    = '|' + ([char]0x2588 -as [string]) * $filled + ([char]0x2591 -as [string]) * $empty + '|'

    if ($script:_pbRow -lt 0) {
        $script:_pbRow = $Host.UI.RawUI.CursorPosition.Y
        [Console]::WriteLine()
        [Console]::WriteLine()
    }

    [Console]::SetCursorPosition(0, $script:_pbRow)
    $Host.UI.RawUI.ForegroundColor = if ($indeterminate) { [ConsoleColor]::DarkCyan } else { [ConsoleColor]::Cyan }
    [Console]::Write($line1)

    [Console]::SetCursorPosition(0, $script:_pbRow + 1)
    $Host.UI.RawUI.ForegroundColor = if ($indeterminate) { [ConsoleColor]::DarkBlue } else { [ConsoleColor]::Blue }
    [Console]::Write($bar)

    $Host.UI.RawUI.ForegroundColor = [ConsoleColor]::White
}

function Clear-ProgressBar {
    if ($script:_pbRow -lt 0) { return }
    $winWidth = $Host.UI.RawUI.WindowSize.Width
    $blank = ' ' * ($winWidth - 1)
    [Console]::SetCursorPosition(0, $script:_pbRow)
    [Console]::WriteLine($blank)
    [Console]::WriteLine($blank)
    [Console]::SetCursorPosition(0, $script:_pbRow)
    $script:_pbRow = -1
}

# ================================================
# ASCII Banner + Apps
# ================================================
Write-Host ""
$lines = @(
    '_________ _      . _______ _________ _______    _______  _________ _______',
    '\__   __/( (    /|(  ____ \\__   __/(  ___  )  (  ____ ) \__   __/(  ____ \',
    '   ) (   |  \  ( || (    \/   ) (   | (   ) |  | (    )|    ) (   | (    \/',
    '   | |   |   \ | || (_____    | |   | (___) |  | (____)|    | |   | |       ',
    '   | |   | (\ \) |(_____  )   | |   |  ___  |  |     __)    | |   | | ____ ',
    '   | |   | | \   |      ) |   | |   | (   ) |  | (\ (       | |   | | \_  )',
    '___) (___| )  \  |/\____) |   | |   | )   ( |  | ) \ \__ ___) (___| (___) |',
    '\_______/|/    )_)\_______)   )_(   |/     \|  |/   \__/ \_______/(_______)'
)
$split = 46
foreach ($line in $lines) {
    $a = if ($line.Length -gt $split) { $line.Substring(0, $split) } else { $line }
    $b = if ($line.Length -gt $split) { $line.Substring($split) } else { '' }
    [Console]::ForegroundColor = [ConsoleColor]::Blue
    [Console]::Write($a)
    [Console]::ForegroundColor = [ConsoleColor]::DarkYellow
    [Console]::WriteLine($b)
}
[Console]::ResetColor()
Write-Host ""

$apps = @(
    @{ Name = 'Brave Browser'; Url = 'https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSilentSetup.exe'; FileName = 'BraveSetup.exe'; Type = 'installer'; SilentArgs = '/silent /install' },
    @{ Name = 'Visual Studio Code'; Url = 'https://update.code.visualstudio.com/latest/win32-x64/stable'; FileName = 'VSCodeSetup.exe'; Type = 'installer'; SilentArgs = '/VERYSILENT /SUPPRESSMSGBOXES /MERGETASKS="!runcode" /DIR="{INSTDIR}"' },
    @{ Name = 'Telegram'; Url = 'https://telegram.org/dl/desktop/win64_portable'; FileName = 'Telegram.zip'; Type = 'zip' },
    @{ Name = 'Spotify'; Url = 'https://download.scdn.co/SpotifySetup.exe'; FileName = 'SpotifySetup.exe'; Type = 'installer'; SilentArgs = '/silent /norestart' }
)

# ================================================
# Download Function
# ================================================
function Download-File {
    param([string]$Url, [string]$Destination, [string]$Label)

    $aria2 = "$env:TEMP\aria2c.exe"
    $ariaZip = "$env:TEMP\aria2.zip"
    $ariaUrl = "https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip"

    if (-not (Test-Path $aria2)) {
        try {
            Invoke-WebRequest -Uri $ariaUrl -OutFile $ariaZip -UseBasicParsing
            $zip = [System.IO.Compression.ZipFile]::OpenRead($ariaZip)
            $entry = $zip.Entries | Where-Object { $_.Name -eq 'aria2c.exe' } | Select-Object -First 1
            if ($entry) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $aria2, $true) }
        } catch {} finally {
            if (Test-Path $ariaZip) { Remove-Item $ariaZip -Force -EA SilentlyContinue }
        }
    }

    if (Test-Path $aria2) {
        try {
            if (Test-Path $Destination) { Remove-Item $Destination -Force }
            $dir = Split-Path $Destination
            $file = Split-Path $Destination -Leaf

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $aria2
            $psi.Arguments = "--split=16 --max-connection-per-server=16 --min-split-size=5M --console-log-level=warn --summary-interval=1 --dir=`"$dir`" --out=`"$file`" `"$Url`""
            $psi.RedirectStandardOutput = $true
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)

            while (-not $proc.HasExited) {
                $line = $proc.StandardOutput.ReadLine()
                if (-not $line) { continue }

                if ($line -match '\[#\w+\s+([\d.]+\w+)/([\d.]+\w+)\((\d+)%\).*DL:([\d.]+\w+)') {
                    $done  = $Matches[1]
                    $total = $Matches[2]
                    $pct   = [int]$Matches[3]
                    $speed = $Matches[4]
                    Show-ProgressBar -Status "Downloading $Label" -Percent $pct -Downloaded "$done/$total" -Speed "$speed/s"
                }
                elseif ($line -match '\((\d+)%\)') {
                    Show-ProgressBar -Status "Downloading $Label" -Percent ([int]$Matches[1])
                }
            }
            $proc.WaitForExit()
            if ($proc.ExitCode -eq 0 -and (Test-Path $Destination)) { return $true }
        }
        catch { }
        finally { Clear-ProgressBar }
    }

    try {
        Show-ProgressBar -Status "Downloading $Label (fallback)" -Percent -1
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $Destination)
        return $true
    }
    catch { return $false }
    finally { Clear-ProgressBar }
}

# ================================================
# Partition + Selection + Installation
# ================================================
Write-Host "Which partition should the 'Apps' subfolder be created on?" -ForegroundColor Cyan
$drives = Get-PSDrive -PSProvider FileSystem | Select-Object Name, @{n='FreeGB';e={[math]::Round($_.Free/1GB,2)}}

for ($i = 0; $i -lt $drives.Count; $i++) {
    Write-Host "  [$($i+1)] $($drives[$i].Name): ($($drives[$i].FreeGB) GB free)"
}

do {
    $driveChoice = Read-Host "  Select a number"
    if ($driveChoice -match '^\d+$' -and $driveChoice -ge 1 -and $driveChoice -le $drives.Count) {
        $chosenDrive = $drives[[int]$driveChoice - 1].Name
        break
    }
    Write-Host "  Invalid choice. Please select a valid number." -ForegroundColor Red
} while ($true)

$AppsRoot = "$($chosenDrive):\Apps"
if (-not (Test-Path $AppsRoot)) { New-Item -ItemType Directory -Path $AppsRoot -Force | Out-Null }

Write-Host "`nSelect apps to install (e.g. 1,3 or A for all):" -ForegroundColor Cyan
for ($i = 0; $i -lt $apps.Count; $i++) { Write-Host "  [$($i+1)] $($apps[$i].Name)" }
$choice = Read-Host "  Your choice"

$selected = if ($choice.Trim().ToUpper() -eq 'A') { $apps }
else {
    $indices = $choice -split ',' | ForEach-Object { $_.Trim() -as [int] }
    $apps | Where-Object { $indices -contains ($apps.IndexOf($_) + 1) }
}

$results = @()
$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($app in $selected) {
    $appDir = Join-Path $AppsRoot $app.Name
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    $tmpFile = Join-Path $env:TEMP $app.FileName

    Write-Host "`n=== $($app.Name) ===" -ForegroundColor White

    if (Download-File -Url $app.Url -Destination $tmpFile -Label $app.Name) {
        try {
            if ($app.Type -eq 'installer') {
                # Improved installer handling
                Show-ProgressBar -Status "Installing $($app.Name)" -Percent -1
                $args = $app.SilentArgs -replace '\{INSTDIR\}', "`"$appDir`""
                $process = Start-Process -FilePath $tmpFile -ArgumentList $args -Wait -PassThru -ErrorAction Stop
                Start-Sleep -Seconds 2  # Give time for installer to finish
            }
            elseif ($app.Type -eq 'zip') {
                # No progress bar for extraction as requested
                Write-Host "  Extracting..." -ForegroundColor Cyan
                Expand-Archive -Path $tmpFile -DestinationPath $appDir -Force
            }
            $results += [PSCustomObject]@{ App = $app.Name; Status = 'SUCCESS' }
            Write-Host "  Installed successfully" -ForegroundColor Green
        }
        catch {
            $results += [PSCustomObject]@{ App = $app.Name; Status = 'FAILED (Install)' }
            Write-Host "  Installation failed: $_" -ForegroundColor Red
        }
        finally { 
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
            Clear-ProgressBar 
        }
    } else {
        $results += [PSCustomObject]@{ App = $app.Name; Status = 'FAILED (Download)' }
    }
}

$totalTimer.Stop()
Write-Host ("`n" + ("=" * 60)) -ForegroundColor DarkGray
Write-Host "                    INSTALLATION SUMMARY" -ForegroundColor White
Write-Host ("=" * 60) -ForegroundColor DarkGray
foreach ($r in $results) {
    $color = if ($r.Status -eq 'SUCCESS') { "Green" } else { "Red" }
    Write-Host "  $($r.Status.PadRight(30)) $($r.App)" -ForegroundColor $color
}
Write-Host "`nTotal time: $($totalTimer.Elapsed.ToString('mm\:ss'))" -ForegroundColor Yellow
Write-Host "Apps location: $AppsRoot" -ForegroundColor Cyan
Write-Host "`nDone!" -ForegroundColor Green
