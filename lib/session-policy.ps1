function Set-WorkstationRegistryValue($path, $name, $type, $value) {
    if (-not (Test-Path -Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    New-ItemProperty -Path $path -Name $name -PropertyType $type -Value $value -Force | Out-Null
}

function Invoke-WorkstationPowerCfg($arguments) {
    $output = @(& powercfg.exe @arguments 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = (($output | ForEach-Object { [string]$_ }) -join "`n")
    }
}

function Invoke-RequiredWorkstationPowerCfg($arguments) {
    $result = Invoke-WorkstationPowerCfg $arguments
    if ($result.ExitCode -ne 0) {
        $message = "powercfg $($arguments -join ' ') failed with exit code $($result.ExitCode)."
        if (-not [string]::IsNullOrWhiteSpace($result.Output)) { $message = "$message $($result.Output)" }
        throw $message
    }
}

function Get-WorkstationPowerSettingDefinitions {
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

function Set-WorkstationPowerValue($scheme, $entry) {
    foreach ($mode in @(
        @{ Name = "AC"; Argument = "/setacvalueindex" },
        @{ Name = "DC"; Argument = "/setdcvalueindex" }
    )) {
        $arguments = @($mode.Argument, $scheme, $entry.Subgroup, $entry.Setting, "0")
        $result = Invoke-WorkstationPowerCfg $arguments
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

function Set-WorkstationPowerValues($scheme) {
    foreach ($entry in @(Get-WorkstationPowerSettingDefinitions)) {
        Set-WorkstationPowerValue $scheme $entry
    }
}

function Disable-WorkstationAutomaticLock {
    Set-WorkstationRegistryValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" InactivityTimeoutSecs DWord 0
    Set-WorkstationRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" NoLockScreen DWord 1

    Set-WorkstationRegistryValue "HKCU:\Control Panel\Desktop" ScreenSaveActive String "0"
    Set-WorkstationRegistryValue "HKCU:\Control Panel\Desktop" ScreenSaverIsSecure String "0"
    Set-WorkstationRegistryValue "HKCU:\Control Panel\Desktop" ScreenSaveTimeOut String "0"
    Remove-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "SCRNSAVE.EXE" -ErrorAction SilentlyContinue

    Set-WorkstationRegistryValue "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop" ScreenSaveActive String "0"
    Set-WorkstationRegistryValue "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop" ScreenSaverIsSecure String "0"
    Set-WorkstationRegistryValue "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop" ScreenSaveTimeOut String "0"
    Set-WorkstationRegistryValue "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon" EnableGoodbye DWord 0

    Set-WorkstationRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" MaxConnectionTime DWord 0
    Set-WorkstationRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" MaxDisconnectionTime DWord 0
    Set-WorkstationRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" MaxIdleTime DWord 0
    Set-WorkstationRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" fPromptForPassword DWord 0
    Set-WorkstationRegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" fResetBroken DWord 0
    Set-WorkstationRegistryValue "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" fPromptForPassword DWord 0
}

function Get-WorkstationPowerValues($entry) {
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

function Set-WorkstationSessionPolicy {
    Invoke-RequiredWorkstationPowerCfg @("/hibernate", "off")
    Invoke-RequiredWorkstationPowerCfg @("/setactive", "SCHEME_MIN")
    Set-WorkstationPowerValues "SCHEME_CURRENT"
    Disable-WorkstationAutomaticLock

    @(Get-WorkstationPowerSettingDefinitions | ForEach-Object { Get-WorkstationPowerValues $_ })
}
