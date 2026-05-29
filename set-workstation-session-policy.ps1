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

function Credentials($cfg) {
    $baseDir = FullPath $cfg.baseDir
    $file = Join-Path $baseDir "credentials.txt"
    $values = @{}
    if (Test-Path -LiteralPath $file) {
        Get-Content -LiteralPath $file | ForEach-Object {
            $parts = $_ -split ":", 2
            if ($parts.Count -eq 2) { $values[$parts[0].Trim()] = $parts[1].Trim() }
        }
    }

    if ([string]::IsNullOrWhiteSpace($cfg.password) -and $values.ContainsKey("Password")) {
        $cfg.password = $values["Password"]
    }
    return $values
}

function SecureText($text) {
    $secure = [Security.SecureString]::new()
    foreach ($ch in ([string]$text).ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return $secure
}

function GuestCredential($cfg) {
    if ([string]::IsNullOrWhiteSpace($cfg.password)) { $null = Credentials $cfg }
    if ([string]::IsNullOrWhiteSpace($cfg.password)) { throw "Missing VM password in config or credentials.txt." }
    [pscredential]::new($cfg.user, (SecureText $cfg.password))
}

$configPath = ArgValue "config"
if ([string]::IsNullOrWhiteSpace($configPath)) {
    throw "Usage: .\set-workstation-session-policy.ps1 --config config\windows.json"
}

$cfg = Get-Content -Raw (FullPath $configPath) | ConvertFrom-Json
@{
    vmName = "WorkstationW11"
    user = "work"
    baseDir = "~/VMs/WorkstationWindows11"
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }

$vm = Get-VM -Name $cfg.vmName -ErrorAction Stop
if ($vm.State -ne "Running") { throw "VM is not running: $($vm.State)" }

$policyPath = Join-Path $PSScriptRoot "lib\session-policy.ps1"
if (-not (Test-Path -LiteralPath $policyPath)) { throw "Missing lib\session-policy.ps1." }
$policyScript = Get-Content -Raw -LiteralPath $policyPath

$state = Invoke-Command -VMName $cfg.vmName -Credential (GuestCredential $cfg) -ArgumentList $policyScript -ScriptBlock {
    param($policyScript)

    $sessionPolicy = [scriptblock]::Create($policyScript)
    . $sessionPolicy
    Set-WorkstationSessionPolicy
}

$bad = @($state | Where-Object { $_.Required -and ((-not $_.Supported) -or $_.AC -ne 0 -or $_.DC -ne 0) })
if ($bad.Count -gt 0) {
    $bad | Format-Table -AutoSize | Out-String | Write-Host
    throw "Some power settings were not set to Never/Disabled."
}

$state | Format-Table -AutoSize
Write-Host "Workstation session policy applied to VM '$($cfg.vmName)'."
