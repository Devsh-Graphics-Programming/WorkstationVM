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

function ChildConfig($cfg, $name) {
    if ($null -eq $cfg.$name) {
        $cfg | Add-Member -Force NoteProperty $name ([pscustomobject]@{})
    }
    return $cfg.$name
}

function Credentials($cfg) {
    $baseDir = FullPath $cfg.baseDir
    $file = Join-Path $baseDir "credentials.txt"
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing credentials file: $file" }

    $values = @{}
    Get-Content -LiteralPath $file | ForEach-Object {
        $parts = $_ -split ":", 2
        if ($parts.Count -eq 2) { $values[$parts[0].Trim()] = $parts[1].Trim() }
    }
    return $values
}

function VmIPv4Addresses($vmName) {
    @(Get-VMNetworkAdapter -VMName $vmName |
        Select-Object -ExpandProperty IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -ne '0.0.0.0' })
}

$configPath = ArgValue "config"
$pin = ArgValue "pin"
$clientName = ArgValue "name"
$hostAddress = ArgValue "host"

if ([string]::IsNullOrWhiteSpace($configPath) -or [string]::IsNullOrWhiteSpace($pin)) {
    throw "Usage: .\pair-moonlight.ps1 --config config\windows.json --pin <moonlight-pin> [--name <client-name>] [--host <vm-ip>]"
}
if ([string]::IsNullOrWhiteSpace($clientName)) { $clientName = $env:COMPUTERNAME }

$cfg = Get-Content -Raw (FullPath $configPath) | ConvertFrom-Json
@{
    vmName = "WorkstationW11"
    baseDir = "~/VMs/WorkstationW11"
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }

$streaming = ChildConfig $cfg "remoteStreaming"
Default $streaming "port" 47989

$credentials = Credentials $cfg
if (-not $credentials.ContainsKey("SunshineUser") -or -not $credentials.ContainsKey("SunshinePassword")) {
    throw "credentials.txt does not contain SunshineUser and SunshinePassword."
}

if ([string]::IsNullOrWhiteSpace($hostAddress)) {
    $hostAddress = VmIPv4Addresses $cfg.vmName | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($hostAddress)) { throw "No usable VM IPv4 address found." }

$webPort = [int]$streaming.port + 1
$pairUrl = "https://$($hostAddress):$webPort/api/pin"
$authText = "$($credentials["SunshineUser"]):$($credentials["SunshinePassword"])"
$headers = @{
    Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($authText))
}
$body = @{
    pin = [string]$pin
    name = [string]$clientName
} | ConvertTo-Json

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
try {
    $request = @{
        Uri = $pairUrl
        Method = "Post"
        Headers = $headers
        Body = $body
        ContentType = "application/json"
    }
    if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey("SkipCertificateCheck")) {
        $request.SkipCertificateCheck = $true
    }
    Invoke-RestMethod @request | Out-Null
} finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback
}

Write-Host "Moonlight pair request sent to $pairUrl for '$clientName'."
