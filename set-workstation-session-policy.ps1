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

$state = Invoke-Command -VMName $cfg.vmName -Credential (GuestCredential $cfg) -ScriptBlock {
    function SetRegistryValue($path, $name, $type, $value) {
        if (-not (Test-Path -Path $path)) {
            New-Item -Path $path -Force | Out-Null
        }
        New-ItemProperty -Path $path -Name $name -PropertyType $type -Value $value -Force | Out-Null
    }

    function InvokePowerCfg($arguments) {
        $output = @(& powercfg.exe @arguments 2>&1)
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = (($output | ForEach-Object { [string]$_ }) -join "`n")
        }
    }

    function RunPowerCfg($arguments) {
        $result = InvokePowerCfg $arguments
        if ($result.ExitCode -ne 0) {
            $message = "powercfg $($arguments -join ' ') failed with exit code $($result.ExitCode)."
            if (-not [string]::IsNullOrWhiteSpace($result.Output)) { $message = "$message $($result.Output)" }
            throw $message
        }
    }

    function PowerSettingDefinitions {
        @(
            @{ Name = "VideoIdle"; Required = $true; Subgroup = "7516b95f-f776-4464-8c53-06167f40cc99"; Setting = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e" },
            @{ Name = "StandbyIdle"; Required = $true; Subgroup = "238c9fa8-0aad-41ed-83f4-97be242c8f20"; Setting = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da" },
            @{ Name = "HibernateIdle"; Required = $true; Subgroup = "238c9fa8-0aad-41ed-83f4-97be242c8f20"; Setting = "9d7815a6-7ee4-497e-8888-515a05f02364" },
            @{ Name = "UnattendedSleep"; Required = $true; Subgroup = "238c9fa8-0aad-41ed-83f4-97be242c8f20"; Setting = "7bc4a2f9-d8fc-4469-b07b-33eb785aaca0" },
            @{ Name = "DiskIdle"; Required = $true; Subgroup = "0012ee47-9041-4b5d-9b77-535fba8b1442"; Setting = "6738e2c4-e8a5-4a42-b16a-e040e769756e" },
            @{ Name = "ConsoleLockDisplay"; Required = $false; Subgroup = "7516b95f-f776-4464-8c53-06167f40cc99"; Setting = "8ec4b3a5-6868-48c2-be75-4f3044be88a7" },
            @{ Name = "RequirePasswordOnWake"; Required = $false; Subgroup = "fea3413e-7e05-4911-9a71-700331f1c294"; Setting = "0e796bdb-100d-47d6-a2d5-f7d2daa51f51" }
        )
    }

    function SetPowerValue($scheme, $entry) {
        foreach ($mode in @(
            @{ Name = "AC"; Argument = "/setacvalueindex" },
            @{ Name = "DC"; Argument = "/setdcvalueindex" }
        )) {
            $arguments = @($mode.Argument, $scheme, $entry.Subgroup, $entry.Setting, "0")
            $result = InvokePowerCfg $arguments
            if ($result.ExitCode -eq 0) { continue }

            $message = "powercfg $($arguments -join ' ') failed for $($entry.Name) ($($mode.Name)) with exit code $($result.ExitCode)."
            if (-not [string]::IsNullOrWhiteSpace($result.Output)) { $message = "$message $($result.Output)" }
            if (-not $entry.Required) {
                Write-Host "Optional power setting skipped: $message"
                continue
            }
            throw $message
        }
    }

    function SetWorkstationPowerValues($scheme) {
        foreach ($entry in @(PowerSettingDefinitions)) {
            SetPowerValue $scheme $entry
        }
    }

    function DisableAutomaticLock {
        SetRegistryValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" InactivityTimeoutSecs DWord 0
        SetRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" NoLockScreen DWord 1

        SetRegistryValue "HKCU:\Control Panel\Desktop" ScreenSaveActive String "0"
        SetRegistryValue "HKCU:\Control Panel\Desktop" ScreenSaverIsSecure String "0"
        SetRegistryValue "HKCU:\Control Panel\Desktop" ScreenSaveTimeOut String "0"
        Remove-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "SCRNSAVE.EXE" -ErrorAction SilentlyContinue

        SetRegistryValue "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop" ScreenSaveActive String "0"
        SetRegistryValue "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop" ScreenSaverIsSecure String "0"
        SetRegistryValue "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop" ScreenSaveTimeOut String "0"
        SetRegistryValue "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" EnableGoodbye DWord 0

        SetRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" MaxConnectionTime DWord 0
        SetRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" MaxDisconnectionTime DWord 0
        SetRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" MaxIdleTime DWord 0
        SetRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" fPromptForPassword DWord 0
        SetRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" fResetBroken DWord 0
        SetRegistryValue "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" fPromptForPassword DWord 0
    }

    function PowerValues($entry) {
        $root = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes"
        $active = [string](Get-ItemPropertyValue -Path $root -Name ActivePowerScheme)
        $path = Join-Path $root (Join-Path $active (Join-Path $entry.Subgroup $entry.Setting))
        $values = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        $supported = $values -and ($values.PSObject.Properties.Name -contains "ACSettingIndex") -and ($values.PSObject.Properties.Name -contains "DCSettingIndex")
        [pscustomobject]@{
            Name = $entry.Name
            Required = [bool]$entry.Required
            Supported = [bool]$supported
            AC = if ($values -and ($values.PSObject.Properties.Name -contains "ACSettingIndex")) { [int64]$values.ACSettingIndex } else { $null }
            DC = if ($values -and ($values.PSObject.Properties.Name -contains "DCSettingIndex")) { [int64]$values.DCSettingIndex } else { $null }
        }
    }

    RunPowerCfg @("/hibernate", "off")

    RunPowerCfg @("/setactive", "SCHEME_MIN")
    SetWorkstationPowerValues "SCHEME_CURRENT"
    DisableAutomaticLock

    @(PowerSettingDefinitions | ForEach-Object { PowerValues $_ })
}

$bad = @($state | Where-Object { $_.Required -and ((-not $_.Supported) -or $_.AC -ne 0 -or $_.DC -ne 0) })
if ($bad.Count -gt 0) {
    $bad | Format-Table -AutoSize | Out-String | Write-Host
    throw "Some power settings were not set to Never/Disabled."
}

$state | Format-Table -AutoSize
Write-Host "Workstation session policy applied to VM '$($cfg.vmName)'."
