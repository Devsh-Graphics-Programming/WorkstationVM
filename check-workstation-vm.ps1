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

function VmIPv4Addresses($vmName) {
    @(Get-VMNetworkAdapter -VMName $vmName |
        Select-Object -ExpandProperty IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -ne '0.0.0.0' })
}

function TestTcpPort($hostName, $port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($hostName, $port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(5000, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function TestSunshineApi($hostAddress, $port, $user, $password, $path) {
    $uri = "https://$($hostAddress):$port$path"
    $authText = "${user}:${password}"
    $headers = @{
        Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($authText))
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $oldCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $restError = ""
    try {
        $request = @{
            Uri = $uri
            Method = "Get"
            Headers = $headers
        }
        if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey("SkipCertificateCheck")) {
            $request.SkipCertificateCheck = $true
        }
        Invoke-RestMethod @request | Out-Null
        return [pscustomobject]@{ Ok = $true; Method = "Invoke-RestMethod"; Message = "" }
    } catch {
        $restError = $_.Exception.Message
    } finally {
        [Net.ServicePointManager]::ServerCertificateValidationCallback = $oldCallback
    }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $curlOutput = @(& $curl.Source "--insecure" "--silent" "--show-error" "--fail" "--user" $authText "--connect-timeout" "10" "--max-time" "20" $uri 2>&1)
            $curlExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($curlExitCode -eq 0) {
            return [pscustomobject]@{ Ok = $true; Method = "curl.exe"; Message = "" }
        }
        $curlError = ($curlOutput | ForEach-Object { [string]$_ }) -join "`n"
        return [pscustomobject]@{ Ok = $false; Method = ""; Message = "Invoke-RestMethod failed: $restError; curl.exe failed with exit code $curlExitCode. $curlError" }
    }

    [pscustomobject]@{ Ok = $false; Method = ""; Message = "Invoke-RestMethod failed: $restError; curl.exe was not found." }
}

function SshKeyPath($cfg) {
    Join-Path (FullPath $cfg.baseDir) "ssh_key_ed25519.key"
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

    $secure = SecureText $cfg.password
    [pscredential]::new($cfg.user, $secure)
}

$configPath = ArgValue "config"
if ([string]::IsNullOrWhiteSpace($configPath)) {
    throw "Usage: .\check-workstation-vm.ps1 --config config\windows.json"
}

$cfg = Get-Content -Raw (FullPath $configPath) | ConvertFrom-Json
@{
    baseDir = "~/VMs/WorkstationW11"
    dataDiskGB = 24
    dataDiskLetter = "W"
    dataDiskLabel = "WorkData"
    dataDiskBitLocker = $true
    sshEnabled = $true
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }

if ($null -eq $cfg.gpu -and $null -ne $cfg.gpuPv) {
    $cfg | Add-Member -Force NoteProperty "gpu" $cfg.gpuPv
}
$gpu = ChildConfig $cfg "gpu"
Default $gpu "enabled" $false
Default $gpu "allocationPercent" 25

$streaming = ChildConfig $cfg "remoteStreaming"
Default $streaming "enabled" $false
Default $streaming "port" 47989

$vm = Get-VM -Name $cfg.vmName -ErrorAction Stop

if ($vm.State -ne "Running") {
    throw "VM is not running: $($vm.State)"
}

Write-Host "VM running: $($vm.Name)"

$credential = GuestCredential $cfg
$sessionState = Invoke-Command -VMName $cfg.vmName -Credential $credential -ArgumentList $cfg.user -ScriptBlock {
    param($expectedUser)

    function RegistryValue($path, $name) {
        $item = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        if (-not $item) { return $null }
        return $item.$name
    }

    function RegistryValueExists($path, $name) {
        $item = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        if (-not $item) { return $false }
        return $null -ne ($item.PSObject.Properties | Where-Object Name -eq $name)
    }

    function PowerValues($subgroup, $setting) {
        $root = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes"
        $active = [string](RegistryValue $root ActivePowerScheme)
        $path = Join-Path $root (Join-Path $active (Join-Path $subgroup $setting))
        $values = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
        [pscustomobject]@{
            AC = if ($values -and ($values.PSObject.Properties.Name -contains "ACSettingIndex")) { [int64]$values.ACSettingIndex } else { $null }
            DC = if ($values -and ($values.PSObject.Properties.Name -contains "DCSettingIndex")) { [int64]$values.DCSettingIndex } else { $null }
        }
    }

    $winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $screen = "HKCU:\Control Panel\Desktop"
    $screenPolicy = "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop"
    $terminalPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    $rdpTcp = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"

    [pscustomobject]@{
        AutoAdminLogon = [string](RegistryValue $winlogon AutoAdminLogon)
        DefaultUserName = [string](RegistryValue $winlogon DefaultUserName)
        HasDefaultPassword = -not [string]::IsNullOrWhiteSpace([string](RegistryValue $winlogon DefaultPassword))
        AutoLogonCountExists = RegistryValueExists $winlogon AutoLogonCount
        InactivityTimeoutSecs = [int](RegistryValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" InactivityTimeoutSecs)
        NoLockScreen = [int](RegistryValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" NoLockScreen)
        ScreenSaveActive = [string](RegistryValue $screen ScreenSaveActive)
        ScreenSaverIsSecure = [string](RegistryValue $screen ScreenSaverIsSecure)
        ScreenSaveTimeOut = [string](RegistryValue $screen ScreenSaveTimeOut)
        ScreenSaveExecutableExists = RegistryValueExists $screen "SCRNSAVE.EXE"
        ScreenSaveActivePolicy = [string](RegistryValue $screenPolicy ScreenSaveActive)
        ScreenSaverIsSecurePolicy = [string](RegistryValue $screenPolicy ScreenSaverIsSecure)
        ScreenSaveTimeOutPolicy = [string](RegistryValue $screenPolicy ScreenSaveTimeOut)
        TerminalServicesMaxConnectionTime = [int](RegistryValue $terminalPolicy MaxConnectionTime)
        TerminalServicesMaxDisconnectionTime = [int](RegistryValue $terminalPolicy MaxDisconnectionTime)
        TerminalServicesMaxIdleTime = [int](RegistryValue $terminalPolicy MaxIdleTime)
        TerminalServicesPromptForPasswordPolicy = [int](RegistryValue $terminalPolicy fPromptForPassword)
        RdpPromptForPassword = [int](RegistryValue $rdpTcp fPromptForPassword)
        RdpPortNumber = [int](RegistryValue $rdpTcp PortNumber)
        RdpListenerEnabled = [int](RegistryValue $rdpTcp fEnableWinStation)
        RdpPortListening = [bool](Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)
        VideoIdle = PowerValues "7516b95f-f776-4464-8c53-06167f40cc99" "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e"
        StandbyIdle = PowerValues "238c9fa8-0aad-41ed-83f4-97be242c8f20" "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"
        HibernateIdle = PowerValues "238c9fa8-0aad-41ed-83f4-97be242c8f20" "9d7815a6-7ee4-497e-8888-515a05f02364"
        UnattendedSleep = PowerValues "238c9fa8-0aad-41ed-83f4-97be242c8f20" "7bc4a2f9-d8fc-4469-b07b-33eb785aaca0"
        DiskIdle = PowerValues "0012ee47-9041-4b5d-9b77-535fba8b1442" "6738e2c4-e8a5-4a42-b16a-e040e769756e"
        ConsoleLockDisplay = PowerValues "7516b95f-f776-4464-8c53-06167f40cc99" "8ec4b3a5-6868-48c2-be75-4f3044be88a7"
        RequirePasswordOnWake = PowerValues "fea3413e-7e05-4911-9a71-700331f1c294" "0e796bdb-100d-47d6-a2d5-f7d2daa51f51"
    }
}

if ($sessionState.AutoAdminLogon -ne "1") { throw "AutoAdminLogon is not enabled." }
if ($sessionState.DefaultUserName -ne $cfg.user) { throw "DefaultUserName is '$($sessionState.DefaultUserName)', expected '$($cfg.user)'." }
if (-not $sessionState.HasDefaultPassword) { throw "DefaultPassword is missing for AutoAdminLogon." }
if ($sessionState.AutoLogonCountExists) { throw "AutoLogonCount still exists, autologon is still count-limited." }
if ($sessionState.InactivityTimeoutSecs -ne 0) { throw "InactivityTimeoutSecs is not disabled." }
if ($sessionState.NoLockScreen -ne 1) { throw "NoLockScreen is not enabled." }
if ($sessionState.ScreenSaveActive -ne "0" -or $sessionState.ScreenSaverIsSecure -ne "0" -or $sessionState.ScreenSaveTimeOut -ne "0") {
    throw "User screensaver lock settings are not disabled."
}
if ($sessionState.ScreenSaveExecutableExists) { throw "A user screensaver executable is still configured." }
if ($sessionState.ScreenSaveActivePolicy -ne "0" -or $sessionState.ScreenSaverIsSecurePolicy -ne "0" -or $sessionState.ScreenSaveTimeOutPolicy -ne "0") {
    throw "User screensaver lock policy is not disabled."
}
if ($sessionState.TerminalServicesMaxConnectionTime -ne 0 -or $sessionState.TerminalServicesMaxDisconnectionTime -ne 0 -or $sessionState.TerminalServicesMaxIdleTime -ne 0) {
    throw "Remote Desktop session time limits are not disabled."
}
if ($sessionState.TerminalServicesPromptForPasswordPolicy -ne 0 -or $sessionState.RdpPromptForPassword -ne 0) {
    throw "Remote Desktop password prompt on reconnect is not disabled."
}
if ($sessionState.RdpPortNumber -ne 3389 -or $sessionState.RdpListenerEnabled -ne 1 -or -not $sessionState.RdpPortListening) {
    throw "Remote Desktop listener is not ready. Port=$($sessionState.RdpPortNumber) Enabled=$($sessionState.RdpListenerEnabled) Listening=$($sessionState.RdpPortListening)"
}

foreach ($setting in @("VideoIdle", "StandbyIdle", "HibernateIdle", "UnattendedSleep", "DiskIdle")) {
    $values = $sessionState.$setting
    if ($null -eq $values.AC -or $null -eq $values.DC -or $values.AC -ne 0 -or $values.DC -ne 0) {
        throw "$setting is not set to Never/Disabled for AC and DC."
    }
}

foreach ($setting in @("ConsoleLockDisplay", "RequirePasswordOnWake")) {
    $values = $sessionState.$setting
    if ($values.AC -ne 0 -or $values.DC -ne 0) {
        Write-Host "Optional power setting not enforced: $setting AC=$($values.AC) DC=$($values.DC)"
    }
}

Write-Host "Interactive session policy ready: autologon=on auto-lock=off power-timeouts=never"

$rdpIps = @(VmIPv4Addresses $cfg.vmName)
if (-not $rdpIps) { throw "No usable VM IPv4 address found for RDP." }
$rdpOk = $false
foreach ($ip in $rdpIps) {
    if (TestTcpPort $ip 3389) {
        Write-Host "RDP ready: $ip`:3389"
        $rdpOk = $true
        break
    }
}
if (-not $rdpOk) { throw "RDP port 3389 is not reachable from the host." }

if ([int]$cfg.dataDiskGB -gt 0) {
    $credentials = Credentials $cfg
    $bitLockerPassword = ""
    if ([bool]$cfg.dataDiskBitLocker) {
        if (-not $credentials.ContainsKey("DataDiskBitLockerPassword")) {
            throw "credentials.txt does not contain DataDiskBitLockerPassword."
        }
        $bitLockerPassword = $credentials["DataDiskBitLockerPassword"]
    }

    $state = Invoke-Command -VMName $cfg.vmName -Credential $credential -ArgumentList $cfg.dataDiskLetter, $cfg.dataDiskLabel, ([bool]$cfg.dataDiskBitLocker), $bitLockerPassword -ScriptBlock {
        param($letter, $label, $expectBitLocker, $bitLockerPassword)

        $letter = ([string]$letter).TrimEnd(":")
        $mountPoint = "${letter}:"
        $bitLocker = if ($expectBitLocker) { Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop } else { $null }
        $wasLocked = $false

        if ($bitLocker -and $bitLocker.LockStatus -eq "Locked") {
            if ([string]::IsNullOrWhiteSpace($bitLockerPassword)) {
                throw "Data disk is BitLocker locked and no password was provided."
            }

            $secure = [Security.SecureString]::new()
            foreach ($ch in ([string]$bitLockerPassword).ToCharArray()) { $secure.AppendChar($ch) }
            $secure.MakeReadOnly()
            Unlock-BitLocker -MountPoint $mountPoint -Password $secure | Out-Null
            $wasLocked = $true

            for ($i = 0; $i -lt 30; $i++) {
                $bitLocker = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop
                if ($bitLocker.LockStatus -ne "Locked") { break }
                Start-Sleep -Seconds 1
            }
        }

        $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
        if ($volume.FileSystemLabel -ne $label) {
            throw "Unexpected data disk label: $($volume.FileSystemLabel)"
        }
        if ($bitLocker) { $bitLocker = Get-BitLockerVolume -MountPoint $mountPoint -ErrorAction Stop }

        [pscustomobject]@{
            DriveLetter = $volume.DriveLetter
            FileSystemLabel = $volume.FileSystemLabel
            SizeGB = [math]::Round($volume.Size / 1GB, 2)
            BitLockerProtection = if ($bitLocker) { [string]$bitLocker.ProtectionStatus } else { "NotChecked" }
            BitLockerStatus = if ($bitLocker) { [string]$bitLocker.VolumeStatus } else { "NotChecked" }
            BitLockerLockStatus = if ($bitLocker) { [string]$bitLocker.LockStatus } else { "NotChecked" }
            BitLockerAutoUnlock = if ($bitLocker) { [bool]$bitLocker.AutoUnlockEnabled } else { $false }
            BitLockerWasLocked = $wasLocked
        }
    }

    if ($state.DriveLetter -ne ([string]$cfg.dataDiskLetter).TrimEnd(":")) {
        throw "Unexpected data disk letter: $($state.DriveLetter)"
    }
    if ($state.FileSystemLabel -ne $cfg.dataDiskLabel) {
        throw "Unexpected data disk label: $($state.FileSystemLabel)"
    }
    if ([bool]$cfg.dataDiskBitLocker -and $state.BitLockerProtection -ne "On") {
        throw "Data disk BitLocker protection is not on: $($state.BitLockerProtection)"
    }
    if ([bool]$cfg.dataDiskBitLocker -and $state.BitLockerAutoUnlock) {
        throw "Data disk BitLocker auto-unlock is enabled."
    }

    $lockNote = if ($state.BitLockerWasLocked) { " unlocked-for-check=true" } else { "" }
    Write-Host "Data disk ready: $($state.DriveLetter): $($state.SizeGB) GB BitLocker=$($state.BitLockerProtection)$lockNote"
}

if ([bool]$cfg.sshEnabled) {
    $key = SshKeyPath $cfg
    if (-not (Test-Path -LiteralPath $key)) { throw "Missing SSH private key: $key" }

    Invoke-Command -VMName $cfg.vmName -Credential $credential -ScriptBlock {
        $service = Get-Service sshd -ErrorAction Stop
        if ($service.Status -ne "Running") { throw "sshd is not running." }
        if (-not (Test-Path "$env:ProgramData\ssh\administrators_authorized_keys")) {
            throw "Missing administrators_authorized_keys."
        }
    }

    $ips = @(Get-VMNetworkAdapter -VMName $cfg.vmName |
        Select-Object -ExpandProperty IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -ne '0.0.0.0' })
    if (-not $ips) { throw "No usable VM IPv4 address found for SSH." }

    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) { throw "ssh.exe was not found on the host." }

    $ok = $false
    $lastSshOutput = ""
    foreach ($ip in $ips) {
        $sshArgs = @(
            "-i", $key,
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=NUL",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10",
            "$($cfg.user)@$ip",
            "echo hello"
        )
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $sshOutput = @(& $ssh.Source @sshArgs 2>&1)
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($exitCode -eq 0) {
            Write-Host "SSH ready: $($cfg.user)@$ip"
            $ok = $true
            break
        }
        $lastSshOutput = ($sshOutput | ForEach-Object { [string]$_ }) -join "`n"
    }
    if (-not $ok) {
        if (-not [string]::IsNullOrWhiteSpace($lastSshOutput)) {
            throw "SSH key login failed. Last ssh output: $lastSshOutput"
        }
        throw "SSH key login failed."
    }
}

if ([bool]$gpu.enabled) {
    $adapter = @(Get-VMGpuPartitionAdapter -VMName $cfg.vmName)
    if ($adapter.Count -ne 1) { throw "Expected one GPU-PV adapter, found $($adapter.Count)." }

    $displayDevices = Invoke-Command -VMName $cfg.vmName -Credential $credential -ScriptBlock {
        @(Get-PnpDevice -PresentOnly -Class Display -ErrorAction SilentlyContinue |
            Select-Object FriendlyName, Status)
    }
    $gpuDevice = $displayDevices |
        Where-Object { $_.FriendlyName -notmatch "Hyper-V|Virtual Display|MttVDD|IddSampleDriver|IDD" -and $_.Status -eq "OK" } |
        Select-Object -First 1
    if (-not $gpuDevice) { throw "No present non-Hyper-V GPU display device is OK inside the guest." }
    Write-Host "GPU-PV ready: $($gpuDevice.FriendlyName)"
}

if ([bool]$streaming.enabled) {
    $credentialValues = Credentials $cfg
    if (-not $credentialValues.ContainsKey("SunshineUser") -or -not $credentialValues.ContainsKey("SunshinePassword")) {
        throw "credentials.txt does not contain SunshineUser and SunshinePassword."
    }

    $streamingState = Invoke-Command -VMName $cfg.vmName -Credential $credential -ArgumentList ([int]$streaming.port) -ScriptBlock {
        param($port)

        $service = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "Sunshine*" -or $_.DisplayName -like "Sunshine*" } |
            Select-Object -First 1
        $vdd = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
            Where-Object { $_.FriendlyName -match "Virtual Display Driver|MttVDD|IddSampleDriver|IDD" } |
            Select-Object -First 1
        $conf = Join-Path $env:ProgramFiles "Sunshine\config\sunshine.conf"
        $webPort = $port + 1

        [pscustomobject]@{
            SunshineServiceName = if ($service) { $service.Name } else { "" }
            SunshineServiceStatus = if ($service) { [string]$service.Status } else { "" }
            SunshineConfigExists = Test-Path -LiteralPath $conf
            VirtualDisplayName = if ($vdd) { $vdd.FriendlyName } else { "" }
            VirtualDisplayStatus = if ($vdd) { [string]$vdd.Status } else { "" }
            WebPortListening = [bool](Get-NetTCPConnection -LocalPort $webPort -State Listen -ErrorAction SilentlyContinue)
        }
    }

    if ($streamingState.SunshineServiceStatus -ne "Running") {
        throw "Sunshine service is not running. Service=$($streamingState.SunshineServiceName) Status=$($streamingState.SunshineServiceStatus)"
    }
    if (-not $streamingState.SunshineConfigExists) { throw "Sunshine config file is missing." }
    if ([string]::IsNullOrWhiteSpace($streamingState.VirtualDisplayName)) { throw "Virtual Display Driver was not detected in the guest." }
    if ($streamingState.VirtualDisplayStatus -ne "OK") { throw "Virtual Display Driver status is $($streamingState.VirtualDisplayStatus)." }
    if (-not $streamingState.WebPortListening) { throw "Sunshine Web UI is not listening in the guest." }

    $ip = VmIPv4Addresses $cfg.vmName | Select-Object -First 1
    if (-not $ip) { throw "No usable VM IPv4 address found for Sunshine." }
    $webPort = [int]$streaming.port + 1
    if (-not (TestTcpPort $ip $webPort)) { throw "Sunshine Web UI is not reachable from host at $ip`:$webPort." }
    $apiProbe = TestSunshineApi $ip $webPort $credentialValues["SunshineUser"] $credentialValues["SunshinePassword"] "/api/config"
    if ($apiProbe.Ok) {
        Write-Host "Sunshine API reachable via $($apiProbe.Method)"
    } else {
        Write-Host "Sunshine API probe warning: $($apiProbe.Message)"
    }

    Write-Host "Moonlight streaming ready: https://${ip}:$webPort"
}
