$ErrorActionPreference = "Continue"

$root = "C:\WorkstationVM"
$log = Join-Path $root "bootstrap.log"
New-Item -ItemType Directory -Force -Path $root | Out-Null
Start-Transcript -Path $log -Append | Out-Null

function SetRegistryValue($path, $name, $type, $value) {
    if (-not (Test-Path -Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    New-ItemProperty -Path $path -Name $name -PropertyType $type -Value $value -Force | Out-Null
}

function EnableRemoteDesktop {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Type DWord -Value 0
    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    Set-NetFirewallRule -Name "RemoteDesktop-UserMode-In-TCP", "RemoteDesktop-UserMode-In-UDP" -Enabled True -ErrorAction SilentlyContinue

    try {
        $group = ([Security.Principal.SecurityIdentifier]"S-1-5-32-555").Translate([Security.Principal.NTAccount]).Value.Split("\")[-1]
        Add-LocalGroupMember -Group $group -Member $env:USERNAME -ErrorAction SilentlyContinue
    } catch {
        Write-Output "Remote Desktop user setup failed: $_"
    }
}

function TuneRemoteDesktop {
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations" -Name DWMFRAMEINTERVAL -PropertyType DWord -Value 15 -Force | Out-Null

    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name InteractiveDelay -PropertyType DWord -Value 0 -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name AVC444ModePreferred -PropertyType DWord -Value 1 -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name SystemResponsiveness -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name NetworkThrottlingIndex -PropertyType DWord -Value 0xffffffff -Force | Out-Null

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name MaxConnectionTime -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name MaxDisconnectionTime -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name MaxIdleTime -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name fPromptForPassword -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name fResetBroken -PropertyType DWord -Value 0 -Force | Out-Null

    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name fPromptForPassword -PropertyType DWord -Value 0 -Force | Out-Null
}

function TunePowerPlan {
    powercfg /hibernate off | Out-Null

    $schemes = @(powercfg /list | ForEach-Object {
        if ($_ -match "Power Scheme GUID:\s+([0-9a-fA-F-]{36})") { $Matches[1] }
    })
    if ($schemes.Count -eq 0) { $schemes = @("SCHEME_CURRENT") }

    foreach ($scheme in $schemes) {
        powercfg /setacvalueindex $scheme SUB_VIDEO VIDEOIDLE 0 | Out-Null
        powercfg /setdcvalueindex $scheme SUB_VIDEO VIDEOIDLE 0 | Out-Null
        powercfg /setacvalueindex $scheme SUB_SLEEP STANDBYIDLE 0 | Out-Null
        powercfg /setdcvalueindex $scheme SUB_SLEEP STANDBYIDLE 0 | Out-Null
        powercfg /setacvalueindex $scheme SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
        powercfg /setdcvalueindex $scheme SUB_SLEEP HIBERNATEIDLE 0 | Out-Null
        powercfg /setacvalueindex $scheme SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0 | Out-Null
        powercfg /setdcvalueindex $scheme SUB_SLEEP 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0 | Out-Null
        powercfg /setacvalueindex $scheme SUB_DISK DISKIDLE 0 | Out-Null
        powercfg /setdcvalueindex $scheme SUB_DISK DISKIDLE 0 | Out-Null
        powercfg /setacvalueindex $scheme SUB_VIDEO 8ec4b3a5-6868-48c2-be75-4f3044be88a7 0 | Out-Null
        powercfg /setdcvalueindex $scheme SUB_VIDEO 8ec4b3a5-6868-48c2-be75-4f3044be88a7 0 | Out-Null
        powercfg /setacvalueindex $scheme fea3413e-7e05-4911-9a71-700331f1c294 0e796bdb-100d-47d6-a2d5-f7d2daa51f51 0 | Out-Null
        powercfg /setdcvalueindex $scheme fea3413e-7e05-4911-9a71-700331f1c294 0e796bdb-100d-47d6-a2d5-f7d2daa51f51 0 | Out-Null
    }

    powercfg /setactive SCHEME_MIN | Out-Null
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
}

function ReadBootstrapConfig($configPath) {
    if (-not (Test-Path -LiteralPath $configPath)) { return [pscustomobject]@{} }

    try {
        return Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    } catch {
        Write-Output "Bootstrap config read failed: $_"
        return [pscustomobject]@{}
    }
}

function EnablePersistentAutoLogon($config) {
    $user = [string]$config.autoLogonUser
    $password = [string]$config.autoLogonPassword
    if ([string]::IsNullOrWhiteSpace($user)) { $user = $env:USERNAME }

    $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    if ([string]::IsNullOrWhiteSpace($password)) {
        $existing = Get-ItemProperty -Path $winlogon -ErrorAction SilentlyContinue
        if ($existing) { $password = [string]$existing.DefaultPassword }
    }
    if ([string]::IsNullOrWhiteSpace($password)) {
        Write-Output "Persistent autologon skipped because no password was available."
        return
    }

    SetRegistryValue $winlogon AutoAdminLogon String "1"
    SetRegistryValue $winlogon DefaultUserName String $user
    SetRegistryValue $winlogon DefaultPassword String $password
    SetRegistryValue $winlogon DefaultDomainName String $env:COMPUTERNAME
    Remove-ItemProperty -Path $winlogon -Name AutoLogonCount -ErrorAction SilentlyContinue

    try {
        Set-LocalUser -Name $user -PasswordNeverExpires $true -ErrorAction Stop
    } catch {
        Write-Output "PasswordNeverExpires setup failed: $_"
    }
}

function ConfigureNetwork($networkPath) {
    if (-not (Test-Path -LiteralPath $networkPath)) { return }

    $config = Get-Content -Raw -LiteralPath $networkPath | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($config.ipAddress)) { return }

    $adapter = Get-NetAdapter | Where-Object Status -eq Up | Select-Object -First 1
    if (-not $adapter) { return }

    if (-not (Get-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $config.ipAddress -ErrorAction SilentlyContinue)) {
        New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $config.ipAddress -PrefixLength ([int]$config.prefixLength) -DefaultGateway $config.gateway | Out-Null
    }
    if ($config.dnsServers) {
        Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses @($config.dnsServers) | Out-Null
    }
}

function EnableSshServer($authorizedKeyPath) {
    if (-not (Test-Path -LiteralPath $authorizedKeyPath)) { return }

    try {
        $capability = Get-WindowsCapability -Online |
            Where-Object Name -like "OpenSSH.Server*" |
            Select-Object -First 1
        if (-not $capability) { throw "OpenSSH Server capability was not found." }
        if ($capability.State -ne "Installed") {
            Add-WindowsCapability -Online -Name $capability.Name -ErrorAction Stop | Out-Null
        }

        $sshDir = Join-Path $env:ProgramData "ssh"
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        $adminKeys = Join-Path $sshDir "administrators_authorized_keys"
        Get-Content -LiteralPath $authorizedKeyPath | Set-Content -LiteralPath $adminKeys -Encoding ascii
        & icacls.exe $adminKeys /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null

        Set-Service -Name sshd -StartupType Automatic -ErrorAction Stop
        Start-Service -Name sshd -ErrorAction Stop
        if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -Profile Any | Out-Null
        } else {
            Set-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -Enabled True -Profile Any | Out-Null
        }
    } catch {
        "OpenSSH Server setup failed: $_" | Out-File -FilePath $log -Append
        Stop-Transcript | Out-Null
        exit 1
    }
}

function Shortcut($name, $target) {
    if (-not (Test-Path -LiteralPath $target)) { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "$name.lnk"))
    $shortcut.TargetPath = $target
    $shortcut.Save()
}

$media = Get-PSDrive -PSProvider FileSystem |
    Where-Object { Test-Path (Join-Path $_.Root "packages.txt") } |
    Select-Object -First 1

$bootstrapConfig = [pscustomobject]@{}
if ($media) {
    $bootstrapConfig = ReadBootstrapConfig (Join-Path $media.Root "bootstrap-config.json")
}

EnableRemoteDesktop
TuneRemoteDesktop
TunePowerPlan
DisableAutomaticLock
EnablePersistentAutoLogon $bootstrapConfig

if ($media) {
    ConfigureNetwork (Join-Path $media.Root "network.json")
    EnableSshServer (Join-Path $media.Root "ssh_authorized_key.pub")
}

$packages = @()
if ($media) {
    $packages = Get-Content -LiteralPath (Join-Path $media.Root "packages.txt") |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

if ($packages.Count -gt 0) {
    for ($i = 0; $i -lt 60; $i++) {
        $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($winget) { break }
        Start-Sleep -Seconds 10
    }

    if (-not $winget) {
        "winget.exe was not found." | Out-File -FilePath $log -Append
        Stop-Transcript | Out-Null
        exit 1
    }

    foreach ($package in $packages) {
        & winget.exe install --id $package --exact --source winget --silent --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Install failed: $package ($LASTEXITCODE)"
        }
    }
}

Shortcut "VS Code" "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
Shortcut "Git Bash" "C:\Program Files\Git\git-bash.exe"
Shortcut "WireGuard" "C:\Program Files\WireGuard\wireguard.exe"
Shortcut "Tor Browser" "$(Join-Path ([Environment]::GetFolderPath("Desktop")) "Tor Browser\Browser\firefox.exe")"

"Done" | Set-Content -LiteralPath (Join-Path $root "bootstrap.done")
Stop-Transcript | Out-Null
