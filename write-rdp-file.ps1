$ErrorActionPreference = "Stop"; $scriptArgs = $args

function ArgValue($name) {
    for ($i = 0; $i -lt $scriptArgs.Count; $i++) {
        if ($scriptArgs[$i] -in @("-$name", "--$name")) { return $scriptArgs[$i + 1] }
    }
    return ""
}

function FullPath($path) {
    $path = [Environment]::ExpandEnvironmentVariables([string]$path)
    if ($path -match '^~[\\/](.*)$') { return (Join-Path $HOME $Matches[1]) }
    if ([IO.Path]::IsPathRooted($path)) { return $path }
    return (Join-Path $PSScriptRoot $path)
}

function Default($cfg, $name, $value) {
    if ($null -eq $cfg.$name) { $cfg | Add-Member -Force NoteProperty $name $value }
}

function VmIPv4Addresses($vmName) {
    @(Get-VMNetworkAdapter -VMName $vmName |
        Select-Object -ExpandProperty IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -ne '0.0.0.0' })
}

$configPath = ArgValue "config"
if ([string]::IsNullOrWhiteSpace($configPath)) {
    throw "Usage: .\write-rdp-file.ps1 --config config\windows.json"
}

$cfg = Get-Content -Raw (FullPath $configPath) | ConvertFrom-Json
@{
    vmName = "WorkstationW11"
    user = "work"
    baseDir = "~/VMs/WorkstationW11"
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }

$ip = VmIPv4Addresses $cfg.vmName | Select-Object -First 1
if ([string]::IsNullOrWhiteSpace($ip)) { throw "No usable VM IPv4 address found for '$($cfg.vmName)'." }

$baseDir = FullPath $cfg.baseDir
New-Item -ItemType Directory -Force -Path $baseDir | Out-Null
$path = Join-Path $baseDir "$($cfg.vmName).rdp"

@(
    "full address:s:${ip}:3389",
    "username:s:$($cfg.user)",
    "prompt for credentials:i:1",
    "screen mode id:i:2",
    "use multimon:i:1",
    "session bpp:i:32",
    "redirectclipboard:i:1",
    "audiomode:i:0",
    "authentication level:i:2",
    "enablecredsspsupport:i:1"
) | Set-Content -LiteralPath $path -Encoding ascii

Write-Host "RDP file: $path"
