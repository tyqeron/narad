[CmdletBinding()]
param([ValidateSet('release','debug')][string]$Mode = 'release')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Build this package on Windows with Visual Studio C++ tools.' }
$Repo = Split-Path -Parent $PSScriptRoot
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}
Push-Location (Join-Path $Repo 'clients/flutter')
try {
    Invoke-Checked 'rustup' @('target','add','x86_64-pc-windows-msvc')
    Invoke-Checked 'flutter' @('pub','get')
    # CMake also builds/copies narad.exe; flutter run -d windows works the same way.
    Invoke-Checked 'flutter' @('build','windows',"--$Mode",'--target-platform','windows-x64')
} finally { Pop-Location }
$Configuration = if ($Mode -eq 'release') { 'Release' } else { 'Debug' }
$Bundle = Join-Path $Repo "clients/flutter/build/windows/x64/runner/$Configuration"
$Dist = Join-Path $Repo 'dist'
$Package = Join-Path $Dist "narad-windows-x64-$Mode"
if (Test-Path $Package) { Remove-Item -Recurse -Force $Package }
New-Item -ItemType Directory -Force $Package | Out-Null
Copy-Item (Join-Path $Bundle '*') $Package -Recurse -Force
foreach ($Required in @('narad_client.exe','narad.exe','flutter_windows.dll','data/icudtl.dat')) {
    if (!(Test-Path (Join-Path $Package $Required))) { throw "Incomplete Windows bundle: $Required missing" }
}
Copy-Item (Join-Path $Repo 'scripts/install-windows.ps1') $Package
Copy-Item (Join-Path $Repo 'scripts/configure-windows-firewall.ps1') $Package
Copy-Item (Join-Path $Repo 'docs/WINDOWS.md') (Join-Path $Package 'README.md')
Copy-Item (Join-Path $Repo 'docs/FIND_DEVICE.md') (Join-Path $Package 'FIND_DEVICE.md')
Copy-Item (Join-Path $Repo 'docs/MEETING.md') (Join-Path $Package 'MEETING.md')
Copy-Item (Join-Path $Repo 'clients/flutter/assets/branding/MaterialIcons_LICENSE.txt') $Package
$Archive = "$Package.zip"
if (Test-Path $Archive) { Remove-Item $Archive -Force }
Compress-Archive -Path $Package -DestinationPath $Archive -CompressionLevel Optimal
$Hash = (Get-FileHash -Algorithm SHA256 $Archive).Hash.ToLowerInvariant()
"$Hash  $([IO.Path]::GetFileName($Archive))" | Set-Content -Encoding ascii "$Archive.sha256"
Write-Host "Windows package: $Archive"
