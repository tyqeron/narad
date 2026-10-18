[CmdletBinding()]
param(
    [ValidateSet('release', 'debug')]
    [string]$Mode = 'release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Ensure the script is running on Windows.
if ($env:OS -ne 'Windows_NT') {
    throw 'Build this package on Windows with Visual Studio C++ tools installed.'
}

# Resolve repository paths.
$Repo = Split-Path -Parent $PSScriptRoot
$FlutterDir = Join-Path $Repo 'clients/flutter'
$Dist = Join-Path $Repo 'dist'

# Verify required commands are available.
foreach ($Command in @('rustup', 'flutter')) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command '$Command' was not found in PATH."
    }
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    Write-Host "`n> $Executable $($Arguments -join ' ')" -ForegroundColor Cyan

    & $Executable @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "'$Executable $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

Push-Location $FlutterDir

try {
    # Verify Flutter and Windows build prerequisites.
    Invoke-Checked 'flutter' @('--version')
    Invoke-Checked 'flutter' @('doctor', '-v')

    # Install the Rust Windows MSVC target.
    Invoke-Checked 'rustup' @(
        'target',
        'add',
        'x86_64-pc-windows-msvc'
    )

    # Resolve Flutter dependencies.
    Invoke-Checked 'flutter' @('pub', 'get')

    # Build the Windows desktop application.
    $BuildArguments = @('build', 'windows')

    if ($Mode -eq 'debug') {
        $BuildArguments += '--debug'
    } else {
        $BuildArguments += '--release'
    }

    Invoke-Checked 'flutter' $BuildArguments
}
finally {
    Pop-Location
}

# Locate the Flutter Windows runner output.
$Configuration = if ($Mode -eq 'release') {
    'Release'
} else {
    'Debug'
}

$Bundle = Join-Path $FlutterDir "build/windows/x64/runner/$Configuration"

if (-not (Test-Path $Bundle -PathType Container)) {
    throw "Build output directory not found: $Bundle"
}

# Validate required application files before packaging.
$RequiredFiles = @(
    'narad_client.exe',
    'narad.exe',
    'flutter_windows.dll',
    'data/icudtl.dat'
)

foreach ($Required in $RequiredFiles) {
    $FilePath = Join-Path $Bundle $Required

    if (-not (Test-Path $FilePath -PathType Leaf)) {
        throw "Incomplete Windows bundle: '$Required' is missing from '$Bundle'."
    }
}

# Prepare the distribution directory.
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

$Package = Join-Path $Dist "narad-windows-x64-$Mode"
$Archive = "$Package.zip"

foreach ($Path in @($Package, $Archive, "$Archive.sha256")) {
    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $Package -Force | Out-Null

# Copy the complete application bundle.
Copy-Item -Path (Join-Path $Bundle '*') `
    -Destination $Package `
    -Recurse `
    -Force

# Copy the installation and documentation files.
$FilesToCopy = @{
    'scripts/install-windows.ps1'                 = 'install-windows.ps1'
    'scripts/configure-windows-firewall.ps1'       = 'configure-windows-firewall.ps1'
    'docs/WINDOWS.md'                             = 'README.md'
    'docs/FIND_DEVICE.md'                         = 'FIND_DEVICE.md'
    'docs/MEETING.md'                             = 'MEETING.md'
    'clients/flutter/assets/branding/MaterialIcons_LICENSE.txt' = 'MaterialIcons_LICENSE.txt'
}

foreach ($Entry in $FilesToCopy.GetEnumerator()) {
    $Source = Join-Path $Repo $Entry.Key
    $Destination = Join-Path $Package $Entry.Value

    if (-not (Test-Path $Source -PathType Leaf)) {
        throw "Required packaging file not found: $Source"
    }

    Copy-Item -Path $Source -Destination $Destination -Force
}

# Verify the packaged application.
foreach ($Required in $RequiredFiles) {
    if (-not (Test-Path (Join-Path $Package $Required) -PathType Leaf)) {
        throw "Packaging failed: '$Required' is missing."
    }
}

# Create the ZIP archive.
Compress-Archive `
    -Path (Join-Path $Package '*') `
    -DestinationPath $Archive `
    -CompressionLevel Optimal

# Generate a SHA-256 checksum.
$Hash = (Get-FileHash -Path $Archive -Algorithm SHA256).Hash.ToLowerInvariant()

"$Hash  $([IO.Path]::GetFileName($Archive))" |
    Set-Content -Path "$Archive.sha256" -Encoding ascii

Write-Host "`nWindows package created successfully:" -ForegroundColor Green
Write-Host "  Directory: $Package"
Write-Host "  Archive:   $Archive"
Write-Host "  SHA-256:   $Hash"
