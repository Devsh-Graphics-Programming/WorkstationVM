$ErrorActionPreference = "Continue"; $scriptArgs = $args

$root = "C:\WorkstationVM"
$log = Join-Path $root "bootstrap.log"
New-Item -ItemType Directory -Force -Path $root | Out-Null
Start-Transcript -Path $log -Append | Out-Null

function ArgValue($name) {
    for ($i = 0; $i -lt $scriptArgs.Count; $i++) {
        if ($scriptArgs[$i] -in @("-$name", "--$name")) { return $scriptArgs[$i + 1] }
    }
    return ""
}

function SetRegistryValue($path, $name, $type, $value) {
    if (-not (Test-Path -Path $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    New-ItemProperty -Path $path -Name $name -PropertyType $type -Value $value -Force | Out-Null
}

function EnableRemoteDesktop {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Type DWord -Value 0
    ConfigureRdpListener
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

function WaitRdpListener($seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        if (Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue) {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function RestartRemoteDesktop {
    Restart-Service -Name TermService -Force -ErrorAction SilentlyContinue
    Start-Service -Name TermService -ErrorAction Stop
    if (-not (WaitRdpListener 60)) {
        throw "Remote Desktop listener did not start on port 3389."
    }
}

function ConfigureRdpListener {
    $rdpTcp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
    SetRegistryValue $rdpTcp PortNumber DWord 3389
    SetRegistryValue $rdpTcp fEnableWinStation DWord 1
    SetRegistryValue $rdpTcp LanAdapter DWord 0
    SetRegistryValue $rdpTcp UserAuthentication DWord 1
    SetRegistryValue $rdpTcp SecurityLayer DWord 2
    SetRegistryValue $rdpTcp MinEncryptionLevel DWord 2
    SetRegistryValue $rdpTcp LoadableProtocol_Object String "{5828227c-20cf-4408-b73f-73ab70b8849f}"
}

function TuneRemoteDesktop {
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations" -Force | Out-Null
    New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations" -Name DWMFRAMEINTERVAL -PropertyType DWord -Value 15 -Force | Out-Null

    ConfigureRdpListener
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

function PackageValue($package, $name, $default) {
    if ($package -is [string]) {
        if ($name -eq "id") { return [string]$package }
        return $default
    }

    $property = $package.PSObject.Properties[$name]
    if ($null -eq $property) { return $default }
    return $property.Value
}

function PackageBool($package, $name, $default) {
    $value = PackageValue $package $name $null
    if ($null -eq $value) { return $default }
    return [bool]$value
}

function ReadWingetPackages($mediaRoot) {
    $jsonPath = Join-Path $mediaRoot "packages.json"
    if (Test-Path -LiteralPath $jsonPath) {
        $items = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
        foreach ($item in $items) { $item }
        return
    }

    $txtPath = Join-Path $mediaRoot "packages.txt"
    if (-not (Test-Path -LiteralPath $txtPath)) { return @() }

    Get-Content -LiteralPath $txtPath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object {
            $line = [string]$_
            $source = "winget"
            $id = $line
            if ($line -match '^([^:]+):(.+)$') {
                $source = $Matches[1]
                $id = $Matches[2]
            }

            [pscustomobject]@{
                id = $id
                source = $source
                exact = $true
                silent = $true
            }
        }
}

function InstallWingetPackage($package) {
    $id = [string](PackageValue $package "id" "")
    if ([string]::IsNullOrWhiteSpace($id)) { return }

    $source = [string](PackageValue $package "source" "winget")
    $name = [string](PackageValue $package "name" $id)
    if ($source -eq "direct") {
        return InstallDirectPackage $package $name
    }

    $override = [string](PackageValue $package "override" "")

    $wingetArgs = @("install", "--id", $id, "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity")
    if (-not [string]::IsNullOrWhiteSpace($source)) { $wingetArgs += @("--source", $source) }
    if (PackageBool $package "exact" $true) { $wingetArgs += "--exact" }
    if (PackageBool $package "silent" $true) { $wingetArgs += "--silent" }
    if (-not [string]::IsNullOrWhiteSpace($override)) { $wingetArgs += @("--override", $override) }

    Write-Output "Installing package: $name"
    & winget.exe @wingetArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Output "Install failed: $name ($LASTEXITCODE)"
        return $false
    }
    return $true
}

function InstallDirectPackage($package, $name) {
    $url = [string](PackageValue $package "url" "")
    if ([string]::IsNullOrWhiteSpace($url)) {
        Write-Output "Install failed: $name (missing url)"
        return $false
    }

    $silentArgs = [string](PackageValue $package "silentArgs" "/S")
    $fileName = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = "$([guid]::NewGuid().ToString("N")).exe" }
    $installer = Join-Path $env:TEMP $fileName

    Write-Output "Installing package: $name"
    Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing -ErrorAction Stop
    $process = Start-Process -FilePath $installer -ArgumentList $silentArgs -Wait -PassThru
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    if ($process.ExitCode -ne 0) {
        Write-Output "Install failed: $name ($($process.ExitCode))"
        return $false
    }

    $checkPath = [string](PackageValue $package "checkPath" "")
    if (-not [string]::IsNullOrWhiteSpace($checkPath) -and -not (Test-Path -LiteralPath $checkPath)) {
        Write-Output "Install failed: $name (missing $checkPath)"
        return $false
    }
    return $true
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

function DownloadLatestGitHubAsset($repo, $assetPattern, $outputPath) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ "User-Agent" = "WorkstationVM-bootstrap" } -ErrorAction Stop
    $asset = $release.assets |
        Where-Object { $_.name -match $assetPattern } |
        Select-Object -First 1
    if (-not $asset) { throw "Could not find release asset '$assetPattern' for $repo." }
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $outputPath -UseBasicParsing -ErrorAction Stop
}

function ConfigureVddSettings($settingsPath, $config) {
    if (-not (Test-Path -LiteralPath $settingsPath)) { return }

    [xml]$xml = Get-Content -Raw -LiteralPath $settingsPath
    $count = [int]$config.virtualDisplayCount
    if ($count -lt 1) { $count = 1 }
    $xml.vdd_settings.monitors.count = [string]$count

    $refresh = [int]$config.refreshRate
    if ($refresh -gt 0) {
        $global = $xml.vdd_settings.global
        if (-not $global) {
            $global = $xml.CreateElement("global")
            $xml.vdd_settings.AppendChild($global) | Out-Null
        }
        $refreshValues = @($global.g_refresh_rate | ForEach-Object { [string]$_ })
        if ($refreshValues -notcontains [string]$refresh) {
            $node = $xml.CreateElement("g_refresh_rate")
            $node.InnerText = [string]$refresh
            $global.AppendChild($node) | Out-Null
        }
    }

    $width = [int]$config.displayWidth
    $height = [int]$config.displayHeight
    if ($width -gt 0 -and $height -gt 0) {
        $resolutions = $xml.vdd_settings.resolutions
        $exists = @($resolutions.resolution | Where-Object {
            [int]$_.width -eq $width -and [int]$_.height -eq $height
        }).Count -gt 0
        if (-not $exists) {
            $resolution = $xml.CreateElement("resolution")
            foreach ($pair in @(
                @{ Name = "width"; Value = $width },
                @{ Name = "height"; Value = $height },
                @{ Name = "refresh_rate"; Value = $(if ($refresh -gt 0) { $refresh } else { 60 }) }
            )) {
                $node = $xml.CreateElement($pair.Name)
                $node.InnerText = [string]$pair.Value
                $resolution.AppendChild($node) | Out-Null
            }
            $resolutions.AppendChild($resolution) | Out-Null
        }
    }

    $xml.Save($settingsPath)
}

function InstallVirtualDisplayDriver($config) {
    if (-not [bool]$config.installVirtualDisplayDriver) { return }

    $configDir = "C:\VirtualDisplayDriver"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    $existing = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match "Virtual Display Driver|MttVDD|IddSampleDriver|IDD" } |
        Select-Object -First 1

    $tempDir = Join-Path $env:TEMP ("WorkstationVM-VDD-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    try {
        $nefconZip = Join-Path $tempDir "nefcon.zip"
        $driverZip = Join-Path $tempDir "driver.zip"
        $driverPattern = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "^VirtualDisplayDriver-ARM64\.Driver\.Only\.zip$" } else { "^VirtualDisplayDriver-x86\.Driver\.Only\.zip$" }

        DownloadLatestGitHubAsset "nefarius/nefcon" "^nefcon_.*\.zip$" $nefconZip
        DownloadLatestGitHubAsset "VirtualDrivers/Virtual-Display-Driver" $driverPattern $driverZip
        Expand-Archive -LiteralPath $nefconZip -DestinationPath $tempDir -Force
        Expand-Archive -LiteralPath $driverZip -DestinationPath $tempDir -Force

        $inf = Get-ChildItem -Path $tempDir -Recurse -Filter "MttVDD.inf" | Select-Object -First 1
        $cat = Get-ChildItem -Path $tempDir -Recurse -Filter "mttvdd.cat" | Select-Object -First 1
        $settings = Get-ChildItem -Path $tempDir -Recurse -Filter "vdd_settings.xml" | Select-Object -First 1
        if (-not $inf -or -not $cat -or -not $settings) { throw "Virtual Display Driver package is missing expected files." }

        Copy-Item -LiteralPath $settings.FullName -Destination (Join-Path $configDir "vdd_settings.xml") -Force
        ConfigureVddSettings (Join-Path $configDir "vdd_settings.xml") $config

        if (-not $existing) {
            $certificates = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
            $certificates.Import([IO.File]::ReadAllBytes($cat.FullName))
            $certDir = Join-Path $tempDir "certs"
            New-Item -ItemType Directory -Force -Path $certDir | Out-Null
            foreach ($cert in $certificates) {
                $certPath = Join-Path $certDir "$($cert.Thumbprint).cer"
                [IO.File]::WriteAllBytes($certPath, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
                & certutil.exe -f -addstore "TrustedPublisher" $certPath | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Failed to import driver certificate $($cert.Thumbprint)." }
            }

            $nefconArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "ARM64" } else { "x64" }
            $nefcon = Get-ChildItem -Path (Join-Path $tempDir $nefconArch) -Filter "nefconw.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $nefcon) { $nefcon = Get-ChildItem -Path $tempDir -Recurse -Filter "nefconw.exe" | Select-Object -First 1 }
            if (-not $nefcon) { throw "nefconw.exe was not found." }

            & $nefcon.FullName install $inf.FullName "Root\MttVDD"
            if ($LASTEXITCODE -ne 0) { throw "Virtual Display Driver install failed with exit code $LASTEXITCODE." }
            Start-Sleep -Seconds 10
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $device = $null
    for ($i = 0; $i -lt 30; $i++) {
        $device = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -match "Virtual Display Driver|MttVDD|IddSampleDriver|IDD" } |
            Select-Object -First 1
        if ($device) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $device) { throw "Virtual Display Driver was not detected after installation." }
}

function SetSunshineConfValue($path, $name, $value) {
    $lines = @()
    if (Test-Path -LiteralPath $path) { $lines = @(Get-Content -LiteralPath $path) }

    $pattern = "^\s*" + [regex]::Escape($name) + "\s*="
    $replacement = "$name = $value"
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) {
            $lines[$i] = $replacement
            $found = $true
        }
    }
    if (-not $found) { $lines += $replacement }
    Set-Content -LiteralPath $path -Value $lines -Encoding ASCII
}

function FindSunshineExe {
    $path = Join-Path $env:ProgramFiles "Sunshine\sunshine.exe"
    if (Test-Path -LiteralPath $path) { return $path }

    $command = Get-Command sunshine.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    return ""
}

function GetSunshineService {
    Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "Sunshine*" -or $_.DisplayName -like "Sunshine*" } |
        Select-Object -First 1
}

function DetectSunshineVirtualDisplayId {
    $tool = Join-Path $env:ProgramFiles "Sunshine\tools\dxgi-info.exe"
    if (-not (Test-Path -LiteralPath $tool)) { return "" }

    try {
        $output = & $tool 2>&1
        $text = $output -join "`n"
        $start = $text.IndexOf("[")
        $end = $text.LastIndexOf("]")
        if ($start -lt 0 -or $end -le $start) { return "" }

        $json = $text.Substring($start, $end - $start + 1)
        $devices = $json | ConvertFrom-Json
        $device = @($devices | Where-Object {
            $_.friendly_name -match "Virtual|VDD|Mtt|IDD"
        }) | Select-Object -First 1
        if ($device -and $device.device_id) { return [string]$device.device_id }
    } catch {
        Write-Output "Sunshine display detection failed: $_"
    }

    return ""
}

function EnsureFirewallRule($name, $displayName, $protocol, $ports) {
    $portValues = @($ports | ForEach-Object { [string]$_ })
    $existing = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
    if ($existing) {
        Set-NetFirewallRule -Name $name -Enabled True -Profile Any -Direction Inbound -Action Allow | Out-Null
        Set-NetFirewallPortFilter -AssociatedNetFirewallRule $existing -Protocol $protocol -LocalPort $portValues | Out-Null
        return
    }

    New-NetFirewallRule -Name $name -DisplayName $displayName -Enabled True -Direction Inbound -Action Allow -Protocol $protocol -LocalPort $portValues -Profile Any | Out-Null
}

function WaitTcpPort($hostName, $port, $seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($hostName, $port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(1000, $false)) {
                $client.EndConnect($async)
                return $true
            }
        } catch {
        } finally {
            $client.Close()
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function ConfigureSunshine($config) {
    if (-not [bool]$config.installSunshine) { return }

    $sunshine = FindSunshineExe
    if ([string]::IsNullOrWhiteSpace($sunshine)) { throw "Sunshine executable was not found after package installation." }

    $configDir = Join-Path $env:ProgramFiles "Sunshine\config"
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null
    $conf = Join-Path $configDir "sunshine.conf"
    if (-not (Test-Path -LiteralPath $conf)) { New-Item -ItemType File -Path $conf -Force | Out-Null }

    $port = [int]$config.port
    if ($port -lt 1029) { $port = 47989 }

    SetSunshineConfValue $conf "sunshine_name" ([string]$config.sunshineName)
    SetSunshineConfValue $conf "address_family" "ipv4"
    SetSunshineConfValue $conf "origin_web_ui_allowed" "lan"
    SetSunshineConfValue $conf "upnp" "disabled"
    SetSunshineConfValue $conf "port" $port
    SetSunshineConfValue $conf "dd_configuration_option" "ensure_active"
    SetSunshineConfValue $conf "dd_resolution_option" "auto"
    SetSunshineConfValue $conf "dd_refresh_rate_option" "auto"
    SetSunshineConfValue $conf "lan_encryption_mode" "0"

    $displayId = DetectSunshineVirtualDisplayId
    if (-not [string]::IsNullOrWhiteSpace($displayId)) {
        SetSunshineConfValue $conf "output_name" $displayId
    }

    $service = GetSunshineService
    if ($service -and $service.Status -eq "Running") {
        Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    & $sunshine --creds ([string]$config.sunshineUser) ([string]$config.sunshinePassword)
    if ($LASTEXITCODE -ne 0) { throw "Sunshine credential setup failed with exit code $LASTEXITCODE." }

    $service = GetSunshineService
    if (-not $service) {
        $installService = Join-Path $env:ProgramFiles "Sunshine\scripts\install-service.bat"
        if (Test-Path -LiteralPath $installService) {
            & cmd.exe /d /c "`"$installService`""
        }
        $service = GetSunshineService
    }
    if (-not $service) { throw "Sunshine service was not found." }

    Set-Service -Name $service.Name -StartupType Automatic
    Start-Service -Name $service.Name

    if ([bool]$config.openFirewall) {
        EnsureFirewallRule "WorkstationVM-Sunshine-TCP" "WorkstationVM Sunshine TCP" "TCP" @(($port - 5), $port, ($port + 1), ($port + 21))
        EnsureFirewallRule "WorkstationVM-Sunshine-UDP" "WorkstationVM Sunshine UDP" "UDP" @(($port + 9), ($port + 10), ($port + 11), ($port + 13))
    }

    if (-not (WaitTcpPort "127.0.0.1" ($port + 1) 120)) {
        throw "Sunshine Web UI did not start on port $($port + 1)."
    }
}

function ConfigureRemoteStreaming($streamingPath) {
    if (-not (Test-Path -LiteralPath $streamingPath)) { return }

    $config = Get-Content -Raw -LiteralPath $streamingPath | ConvertFrom-Json
    if (-not [bool]$config.enabled) { return }

    InstallVirtualDisplayDriver $config
    ConfigureSunshine $config
}

function Shortcut($name, $target) {
    if (-not (Test-Path -LiteralPath $target)) { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "$name.lnk"))
    $shortcut.TargetPath = $target
    $shortcut.Save()
}

$streamingConfigPath = ArgValue "streaming-config"
if (-not [string]::IsNullOrWhiteSpace($streamingConfigPath)) {
    $ErrorActionPreference = "Stop"
    ConfigureRemoteStreaming $streamingConfigPath
    "RemoteStreamingDone" | Set-Content -LiteralPath (Join-Path $root "streaming.done")
    Stop-Transcript | Out-Null
    return
}

$media = Get-PSDrive -PSProvider FileSystem |
    Where-Object { Test-Path (Join-Path $_.Root "packages.txt") } |
    Select-Object -First 1

$bootstrapConfig = [pscustomobject]@{}
if ($media) {
    $bootstrapConfig = ReadBootstrapConfig (Join-Path $media.Root "bootstrap-config.json")
}

Write-Output "Configuring Remote Desktop"
EnableRemoteDesktop
TuneRemoteDesktop
RestartRemoteDesktop
Write-Output "Configuring power and lock policy"
TunePowerPlan
DisableAutomaticLock
EnablePersistentAutoLogon $bootstrapConfig

if ($media) {
    Write-Output "Configuring network and SSH"
    ConfigureNetwork (Join-Path $media.Root "network.json")
    EnableSshServer (Join-Path $media.Root "ssh_authorized_key.pub")
}

$packages = @()
if ($media) {
    $packages = @(ReadWingetPackages $media.Root)
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

    $failedPackages = @()
    foreach ($package in $packages) {
        if (-not (InstallWingetPackage $package)) {
            $failedPackages += [string](PackageValue $package "name" (PackageValue $package "id" "unknown"))
        }
    }
    if ($failedPackages.Count -gt 0) {
        "Package install failures: $($failedPackages -join ', ')" | Out-File -FilePath $log -Append
        Stop-Transcript | Out-Null
        exit 1
    }
}

Shortcut "VS Code" "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe"
Shortcut "Git Bash" "C:\Program Files\Git\git-bash.exe"
Shortcut "WireGuard" "C:\Program Files\WireGuard\wireguard.exe"
Shortcut "Tor Browser" "$(Join-Path ([Environment]::GetFolderPath("Desktop")) "Tor Browser\Browser\firefox.exe")"
Shortcut "Google Chrome" "C:\Program Files\Google\Chrome\Application\chrome.exe"
Shortcut "Visual Studio 2026" "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\devenv.exe"
Shortcut "ThinLinc Client" "C:\Program Files\ThinLinc client\tlclient.exe"

"Done" | Set-Content -LiteralPath (Join-Path $root "bootstrap.done")
Stop-Transcript | Out-Null
