[CmdletBinding()]
param([string]$PackageDirectory = $PSScriptRoot,
      [string]$Destination = (Join-Path $env:LOCALAPPDATA 'Programs/Narad'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Run this installer on Windows.' }
$PackageDirectory = (Resolve-Path $PackageDirectory).Path
$Destination = [IO.Path]::GetFullPath($Destination)
foreach ($Name in @('narad_client.exe','narad.exe','flutter_windows.dll','data')) {
    if (!(Test-Path (Join-Path $PackageDirectory $Name))) { throw "Extract the complete Windows package first ($Name missing)." }
}
if ($PackageDirectory.TrimEnd('\') -eq $Destination.TrimEnd('\')) { throw 'Choose an installation folder different from the extracted package.' }
foreach ($Process in Get-Process -Name narad_client,narad -ErrorAction SilentlyContinue) {
    if ($Process.Path -and $Process.Path.StartsWith("$Destination\", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Close Narad before updating the installed application.'
    }
}
New-Item -ItemType Directory -Force $Destination | Out-Null
Copy-Item (Join-Path $PackageDirectory '*') $Destination -Recurse -Force
$Shell = New-Object -ComObject WScript.Shell
$Menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Narad.lnk'
$Shortcut = $Shell.CreateShortcut($Menu)
$Shortcut.TargetPath = Join-Path $Destination 'narad_client.exe'
$Shortcut.WorkingDirectory = $Destination
$Shortcut.IconLocation = "$Destination\narad_client.exe,0"
$Shortcut.Save()
Write-Host "Installed Narad: $Destination"
Write-Host 'Open Narad from Start. Account data remains in %LOCALAPPDATA%\Narad\state.'
