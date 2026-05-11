# Windows App Installer (`insta_rig.ps1`)

An interactive PowerShell utility is made to be used after a **fresh Windows install**, where manually installing your essential apps is tedious. It **downloads, installs, and (when supported) updates** a curated set of applications, supports **dynamic “latest” download URLs** and **installation detection**, and finishes with a concise, color-coded summary including **install locations**.

## Features

- **Admin auto-elevation** (relaunches itself as Administrator when needed)
- **Drive selection** for an `Apps` folder (e.g. `D:\Apps`)
- **Interactive app selection** (pick individual apps or install all)
- **Fast downloads** via `aria2c` (auto-fetched) with `Invoke-WebRequest` fallback
- **Installer + ZIP support**
  - Installer apps: runs silent installer arguments
  - ZIP apps: extracts into the chosen `Apps` folder
- **Installed app detection**
  - Uses Windows “Uninstall” registry entries (HKLM/HKCU, 32/64-bit)
  - Falls back to deriving location from `DisplayIcon` / `UninstallString` when needed
- **Best-effort update behavior**
  - For some apps, fetches “latest version” from the vendor source and updates when outdated
  - For **Steam** and **Discord**, it only checks existence (they self-update)
- **Clean output**
  - **Red is used only for errors**
  - Summary prints app status plus **install location** (location is shown in gray)

## Requirements

- Windows 10/11
- PowerShell 5.1+ or PowerShell 7+
- Internet access
- Ability to run scripts (for example, `ExecutionPolicy` set to allow local scripts)

> The script downloads `aria2c` to your temp folder when available. If that fetch fails, it automatically falls back to the built-in downloader.

## Usage

In **Windows Terminal (Admin)**, paste one of the following and press Enter.

### Run from GitHub (recommended)

```powershell
irm https://raw.githubusercontent.com/ShamsKabir/insta_rig/main/insta_rig.ps1 | iex
```

### Run from shortened URL

```powershell
irm https://tinyurl.com/instaRig | iex
```

### Run locally (development)

```powershell
cd C:\Users\<yourUserName>\Downloads
.\insta_rig.ps1
```

You will be prompted to:

- Choose a drive/partition (the script uses `<Drive>:\Apps`)
- Select apps by number (comma-separated) or `A` for all

## Where apps are installed

- **ZIP apps**: extracted into the selected `Apps` folder, typically:
  - `<Drive>:\Apps\<App Name>\...`
- **Installer apps**:
  - If the installer supports a custom path, the script passes `{INSTDIR}` accordingly.
  - If an installer ignores custom paths, it installs to its default location.

At the end, the summary prints each app’s **detected install location**:

- Prefer `InstallLocation` from the registry (when present and valid)
- Otherwise derive from `DisplayIcon` / `UninstallString`
- Otherwise `-` (unknown)

## Update / skip behavior

The script follows these rules:

- If an app is **not installed**: it will install it.
- If an app is **installed**:
  - If it is marked as **self-updating** (Steam/Discord): it **skips**
  - If the script can determine **latest version** and compare: it **updates only when outdated**
  - If it cannot compare versions but has an always-latest URL: it may **re-run installer** to update/repair (app-dependent)

## Customizing the app list

Apps are defined in the `$apps` array inside `insta_rig.ps1`.

Common fields:

- `Name`: Display name
- `Url`: Download URL (can be “always-latest”)
- `DynamicUrlScript`: Script block to resolve the latest URL at runtime
- `Type`: `installer` or `zip`
- `FileName`: Temporary download filename
- `SilentArgs`: Installer silent arguments (use `{INSTDIR}` placeholder when supported)
- `NoInstDir`: `$true` if the app cannot be installed to a custom location
- `Detect.MatchNames`: Names used to find the app in uninstall registry entries
- `Detect.ExeRelativePath`: Used to read version from the main executable (when registry version is missing)
- `LatestVersionScript`: Script block returning a version string (best-effort)
- `SkipUpdateIfInstalled`: `$true` to always skip updates when installed (used for self-updating apps)

## Troubleshooting

- **“Download failed”**
  - Check internet connectivity and that your environment can reach the vendor URLs.
  - Some networks block GitHub/API calls; try again on a different network.

- **“Installed location is wrong / empty”**
  - Some apps do not populate `InstallLocation` in the registry.
  - The script falls back to `DisplayIcon` / `UninstallString`, but results can vary by installer.

- **Installer UI still appears**
  - The silent arguments may not match that vendor’s installer type/version.
  - Update `SilentArgs` for the affected app.

## Notes and limitations

- Vendor download pages and endpoints can change over time; dynamic URL scripts and version probes are **best-effort**.
- Not all apps provide a reliable public “latest version” endpoint.
- Some installers ignore custom directory flags; the script avoids creating empty folders in that case.

