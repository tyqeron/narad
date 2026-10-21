[CmdletBinding()]
param(
    [ValidateSet('release','debug')][string]$Mode = 'release',
    [switch]$SkipBuild,
    [string]$Version,
    [string]$Publisher = 'CN=Narad',
    [string]$CertificatePfx = $env:NARAD_WINDOWS_PFX
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'Build MSIX on Windows with the Windows SDK installed.' }
$Repo = Split-Path -Parent $PSScriptRoot
if (-not $SkipBuild) { & "$PSScriptRoot/build-windows.ps1" -Mode $Mode }
$Bundle = Join-Path $Repo "dist/narad-windows-x64-$Mode"
foreach ($Name in @('narad_client.exe','narad.exe','flutter_windows.dll','data')) {
    if (-not (Test-Path (Join-Path $Bundle $Name))) { throw "Incomplete Windows bundle: $Name" }
}
if (-not $Version) {
    $Pubspec = Get-Content "$Repo/clients/flutter/pubspec.yaml" -Raw
    if ($Pubspec -notmatch '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)(?:-[^+\s]+)?\+(\d+)\s*$') { throw 'Cannot derive MSIX version from pubspec.yaml.' }
    $Version = "$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
}
if ($Version -notmatch '^\d+\.\d+\.\d+\.\d+$' -or @($Version.Split('.') | Where-Object { [long]$_ -gt 65535 }).Count) {
    throw 'Pass -Version with four components in the range 0..65535.'
}
$SdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits/10/bin'
$Sdk = Get-ChildItem $SdkRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'x64/makeappx.exe') } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $Sdk) { throw 'Windows SDK MakeAppx.exe not found.' }
$MakeAppx = Join-Path $Sdk.FullName 'x64/makeappx.exe'
$SignTool = Join-Path $Sdk.FullName 'x64/signtool.exe'
if ($CertificatePfx) {
    $Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePfx, $env:NARAD_WINDOWS_PFX_PASSWORD, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    try { $Publisher = $Certificate.Subject } finally { $Certificate.Dispose() }
}
$Stage = Join-Path ([IO.Path]::GetTempPath()) ('narad-msix-'+[guid]::NewGuid().ToString('N'))
$Suffix = if ($CertificatePfx) { '' } else { '-unsigned' }
$Output = Join-Path $Repo "dist/narad-windows-x64-$Mode$Suffix.msix"
try {
    New-Item -ItemType Directory -Path "$Stage/Assets" -Force | Out-Null
    Copy-Item (Join-Path $Bundle '*') $Stage -Recurse -Force
    $Manifest = Get-Content "$Repo/clients/flutter/windows/packaging/AppxManifest.xml" -Raw
    $Manifest.Replace('@PUBLISHER@',[Security.SecurityElement]::Escape($Publisher)).Replace('@VERSION@',$Version) |
        Set-Content "$Stage/AppxManifest.xml" -Encoding utf8
    Add-Type -AssemblyName System.Drawing
    $Image = [Drawing.Image]::FromFile("$Repo/clients/flutter/assets/branding/narad.png")
    try {
        foreach ($Asset in @(@('StoreLogo',50),@('Square44x44Logo',44),@('Square150x150Logo',150))) {
            $Bitmap = [Drawing.Bitmap]::new($Image,[int]($Asset[1]),[int]($Asset[1]))
            try { $Bitmap.Save("$Stage/Assets/$($Asset[0]).png",[Drawing.Imaging.ImageFormat]::Png) }
            finally { $Bitmap.Dispose() }
        }
    } finally { $Image.Dispose() }
    & $MakeAppx pack /d $Stage /p $Output /o
    if ($LASTEXITCODE) { throw 'MakeAppx validation/packaging failed.' }
    if ($CertificatePfx) {
        $SignArguments = @('sign','/fd','SHA256','/f',$CertificatePfx)
        if ($env:NARAD_WINDOWS_PFX_PASSWORD) { $SignArguments += @('/p',$env:NARAD_WINDOWS_PFX_PASSWORD) }
        $SignArguments += $Output
        & $SignTool @SignArguments
        if ($LASTEXITCODE) { throw 'MSIX signing failed. Check the certificate and password.' }
    }
    $Hash = (Get-FileHash $Output -Algorithm SHA256).Hash.ToLowerInvariant()
    "$Hash  $([IO.Path]::GetFileName($Output))" | Set-Content "$Output.sha256" -Encoding ascii
    Write-Host "MSIX created: $Output"
    if (-not $CertificatePfx) { Write-Host 'Unsigned review package: sign it with a trusted matching publisher certificate before installation.' }
} finally {
    if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
}
