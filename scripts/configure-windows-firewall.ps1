[CmdletBinding()]
param([string]$InstallDirectory = $PSScriptRoot, [switch]$Remove)
$ErrorActionPreference = 'Stop'
$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = [Security.Principal.WindowsPrincipal]::new($Identity)
if (!$Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this optional firewall helper in an Administrator PowerShell window.'
}
$Daemon = Join-Path (Resolve-Path $InstallDirectory).Path 'narad.exe'
if (!(Test-Path $Daemon)) { throw 'Point -InstallDirectory at the extracted or installed Narad package.' }
# Deterministic names per installation: do not modify unrelated firewall rules.
$Hasher = [Security.Cryptography.SHA256]::Create()
try { $Digest = $Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Daemon.ToLowerInvariant())) }
finally { $Hasher.Dispose() }
$Tag = ([BitConverter]::ToString($Digest)).Replace('-','').Substring(0,12)
foreach ($Rule in @(@('Control','TCP','45678-45679'), @('Discovery','UDP','5353'))) {
    $Name = "Narad-$Tag-$($Rule[0])"
    Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    if (!$Remove) {
        New-NetFirewallRule -Name $Name -DisplayName "Narad $($Rule[0]) ($Tag)" `
            -Program $Daemon -Direction Inbound -Action Allow -Profile Private `
            -RemoteAddress LocalSubnet -Protocol $Rule[1] -LocalPort $Rule[2] | Out-Null
    }
}
Write-Host 'Narad private-LAN firewall rules updated. The localhost API is not exposed.'
