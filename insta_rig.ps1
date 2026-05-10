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
# Progress Bar
# ================================================
$script:_pbRow = -1

function Show-ProgressBar {
    param(
        [string]$Status,
        [int]$Percent = -1,
        [string]$Downloaded = '',
        [string]$Speed = ''
    )

    $winWidth = $Host.UI.RawUI.WindowSize.Width

    $stats = (@($Downloaded, $(if ($Speed) { "@ $Speed" })) | Where-Object { $_ }) -join '  '
    $pctLabel = if ($Percent -lt 0) { '  --  ' } else { "$Percent%" }

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
        $script:_pbRow = $Host.UI.RawUI.CursorPosition.Y
        [Console]::WriteLine()
        [Console]::WriteLine()
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

# ================================================
# ASCII Banner
# ================================================
Write-Host ''
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
$apps = @(
    [ordered]@{
        Name       = 'Brave Browser'
        Url        = 'https://github.com/brave/brave-browser/releases/latest/download/BraveBrowserStandaloneSilentSetup.exe'
        FileName   = 'BraveSetup.exe'
        Type       = 'installer'
        SilentArgs = '/silent /install'
    },
    [ordered]@{
        Name       = 'Visual Studio Code'
        Url        = 'https://update.code.visualstudio.com/latest/win32-x64/stable'
        FileName   = 'VSCodeSetup.exe'
        Type       = 'installer'
        # /DIR= tells Inno Setup where to install; no extra quotes needed inside the arg string
        SilentArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /MERGETASKS=!runcode /DIR={INSTDIR}'
    },
    [ordered]@{
        Name     = 'Telegram'
        Url      = 'https://telegram.org/dl/desktop/win64_portable'
        FileName = 'Telegram.zip'
        Type     = 'zip'
    },
    [ordered]@{
        Name       = 'Spotify'
        Url        = 'https://download.scdn.co/SpotifySetup.exe'
        FileName   = 'SpotifySetup.exe'
        Type       = 'installer'
        SilentArgs = '/silent /norestart'
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
            Write-Host "  aria2c exited with code $($proc.ExitCode); falling back." -ForegroundColor DarkYellow
        }
        catch {
            Write-Host "  aria2c error: $_" -ForegroundColor DarkYellow
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
        Write-Host "  Download failed: $_" -ForegroundColor Red
        return $false
    }
    finally {
        Clear-ProgressBar
    }
}

# ================================================
# Drive / Partition Selection
# ================================================
Write-Host "Which partition should the 'Apps' subfolder be created on?" -ForegroundColor Cyan

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
        Write-Host '  Invalid choice. Please enter a valid number.' -ForegroundColor Red
    }
} while (-not $chosenDrive)

$AppsRoot = "$($chosenDrive):\Apps"
if (-not (Test-Path $AppsRoot)) { New-Item -ItemType Directory -Path $AppsRoot -Force | Out-Null }

# ================================================
# App Selection
# ================================================
Write-Host "`nSelect apps to install (e.g. 1,3  or  A for all):" -ForegroundColor Cyan
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
        Write-Host '  No valid selection. Try again.' -ForegroundColor Red
    }
} while (-not $selected)

# ================================================
# Download & Install Loop
# ================================================
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($app in $selected) {
    Write-Host "`n=== $($app.Name) ===" -ForegroundColor White

    $appDir = Join-Path $AppsRoot $app.Name
    if (-not (Test-Path $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null }

    $tmpFile = Join-Path $env:TEMP $app.FileName
    # Clean up any leftover temp file from a previous run
    if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }

    $downloaded = Download-File -Url $app.Url -Destination $tmpFile -Label $app.Name

    if (-not $downloaded) {
        $results.Add([PSCustomObject]@{ App = $app.Name; Status = 'FAILED (Download)' })
        continue
    }

    $status = 'FAILED (Install)'
    try {
        switch ($app.Type) {

            'installer' {
                Show-ProgressBar -Status "Installing $($app.Name)" -Percent -1

                # Substitute {INSTDIR} placeholder with the actual target directory
                $resolvedArgs = $app.SilentArgs -replace '\{INSTDIR\}', $appDir

                $proc = Start-Process -FilePath $tmpFile `
                    -ArgumentList $resolvedArgs `
                    -Wait -PassThru -ErrorAction Stop

                # Give the installer a moment to fully release file handles
                Start-Sleep -Seconds 3
                Clear-ProgressBar

                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
                    # 3010 = success, reboot required (Spotify/VS Code)
                    $status = 'SUCCESS'
                    Write-Host "  Installed successfully (exit $($proc.ExitCode))" -ForegroundColor Green
                }
                else {
                    Write-Host "  Installer returned exit code $($proc.ExitCode)" -ForegroundColor Red
                }
            }

            'zip' {
                Write-Host '  Extracting...' -ForegroundColor Cyan

                # Extract to a staging folder so we can handle nested top-level dirs cleanly
                $stagingDir = Join-Path $env:TEMP "$($app.Name)_extract"
                if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }

                [System.IO.Compression.ZipFile]::ExtractToDirectory($tmpFile, $stagingDir)

                # If the zip contains exactly one top-level folder, move its contents up
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
                Write-Host '  Extracted successfully' -ForegroundColor Green
            }

            default {
                Write-Host "  Unknown app type '$($app.Type)'" -ForegroundColor Red
            }
        }
    }
    catch {
        Clear-ProgressBar
        Write-Host "  Error: $_" -ForegroundColor Red
    }
    finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }

    $results.Add([PSCustomObject]@{ App = $app.Name; Status = $status })
}

$totalTimer.Stop()

# ================================================
# Summary
# ================================================
Write-Host ("`n" + ('=' * 60)) -ForegroundColor DarkGray
Write-Host '                    INSTALLATION SUMMARY'   -ForegroundColor White
Write-Host ('=' * 60)                                   -ForegroundColor DarkGray

foreach ($r in $results) {
    $color = if ($r.Status -eq 'SUCCESS') { 'Green' } else { 'Red' }
    Write-Host "  $($r.Status.PadRight(30)) $($r.App)" -ForegroundColor $color
}

Write-Host "`nTotal time:    $($totalTimer.Elapsed.ToString('mm\:ss'))" -ForegroundColor Yellow
Write-Host "Apps location: $AppsRoot"                                   -ForegroundColor Cyan
Write-Host "`nDone!" -ForegroundColor Green
