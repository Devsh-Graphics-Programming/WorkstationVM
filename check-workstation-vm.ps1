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

$configPath = ArgValue "config"
if ([string]::IsNullOrWhiteSpace($configPath)) {
    throw "Usage: .\check-workstation-vm.ps1 --config config\windows11.json"
}

$cfg = Get-Content -Raw (FullPath $configPath) | ConvertFrom-Json
$vm = Get-VM -Name $cfg.vmName -ErrorAction Stop

if ($vm.State -ne "Running") {
    throw "VM is not running: $($vm.State)"
}

Write-Host "VM running: $($vm.Name)"
