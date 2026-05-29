$ErrorActionPreference = "Stop"; $scriptArgs = $args

function ArgValue($name, $defaultValue = "") {
    for ($i = 0; $i -lt $scriptArgs.Count; $i++) {
        if ($scriptArgs[$i] -in @("-$name", "--$name")) { return $scriptArgs[$i + 1] }
    }
    return $defaultValue
}

function Flag($name) {
    for ($i = 0; $i -lt $scriptArgs.Count; $i++) {
        if ($scriptArgs[$i] -in @("-$name", "--$name")) { return $true }
    }
    return $false
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

function Log($scope, $message) {
    Write-Host ("[{0}] {1}" -f $scope, $message)
}

function AssertAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from PowerShell as Administrator. Hyper-V switch and host interface setup require an elevated token."
    }
}

function GuestCredential($cfg) {
    $path = Join-Path (FullPath $cfg.baseDir) "credentials.txt"
    if (-not (Test-Path -LiteralPath $path)) { throw "Credentials file '$path' was not found." }

    $content = Get-Content -LiteralPath $path
    $userLine = $content | Where-Object { $_ -match '^User:\s*(.+)$' } | Select-Object -First 1
    $passwordLine = $content | Where-Object { $_ -match '^Password:\s*(.+)$' } | Select-Object -First 1
    if (-not $userLine -or -not $passwordLine) { throw "Credentials file '$path' does not contain User and Password lines." }

    $user = [regex]::Match($userLine, '^User:\s*(.+)$').Groups[1].Value
    $password = [regex]::Match($passwordLine, '^Password:\s*(.+)$').Groups[1].Value
    $secure = [Security.SecureString]::new()
    foreach ($ch in $password.ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    [pscredential]::new($user, $secure)
}

function AssertNoSubnetNat($subnetPrefix) {
    $matches = @(Get-NetNat -ErrorAction SilentlyContinue |
        Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $subnetPrefix })
    if ($matches.Count -gt 0) {
        throw "A NetNat already exists for '$subnetPrefix'. Refusing to use the management subnet with NAT enabled."
    }
    Log "host" "NAT for ${subnetPrefix}: none"
}

function EnsureInternalSwitch($switchName) {
    $switch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if (-not $switch) {
        Log "host" "Creating internal Hyper-V switch '$switchName'"
        return (New-VMSwitch -Name $switchName -SwitchType Internal)
    }
    if ($switch.SwitchType -ne "Internal") {
        throw "Switch '$switchName' already exists but is '$($switch.SwitchType)', not Internal."
    }
    Log "host" "Internal Hyper-V switch '$switchName' already exists"
    return $switch
}

function EnsureHostAddress($switchName, $hostIp, $prefixLength) {
    $alias = "vEthernet ($switchName)"
    $adapter = Get-NetAdapter -Name $alias -ErrorAction Stop
    if ($adapter.Status -eq "Disabled") {
        Log "host" "Enabling $alias"
        Enable-NetAdapter -Name $alias -Confirm:$false | Out-Null
    }

    Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -Forwarding Disabled -WeakHostReceive Disabled -WeakHostSend Disabled | Out-Null
    Set-DnsClient -InterfaceAlias $alias -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue | Out-Null
    Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses -ErrorAction SilentlyContinue | Out-Null

    $defaultRoutes = @(Get-NetRoute -InterfaceAlias $alias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue)
    foreach ($route in $defaultRoutes) {
        Log "host" "Removing default route from $alias"
        Remove-NetRoute -InputObject $route -Confirm:$false
    }

    $addresses = @(Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne $hostIp -and $_.PrefixOrigin -ne "WellKnown" })
    foreach ($address in $addresses) {
        Log "host" "Removing extra IPv4 $($address.IPAddress) from $alias"
        Remove-NetIPAddress -InterfaceAlias $alias -IPAddress $address.IPAddress -Confirm:$false
    }

    $existing = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -IPAddress $hostIp -ErrorAction SilentlyContinue
    if (-not $existing) {
        Log "host" "Configuring $alias = $hostIp/$prefixLength"
        New-NetIPAddress -InterfaceAlias $alias -IPAddress $hostIp -PrefixLength $prefixLength -AddressFamily IPv4 | Out-Null
    } else {
        Log "host" "$alias already has $hostIp/$prefixLength"
    }

    return $alias
}

function EnsureVmAdapter($vmName, $switchName, $adapterName) {
    $vm = Get-VM -Name $vmName -ErrorAction Stop
    if ($vm.State -ne "Running") { throw "VM '$vmName' must be running. This script does not shut down or restart the VM." }

    $adapter = Get-VMNetworkAdapter -VMName $vmName -Name $adapterName -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Log "vm" "Adding VM management adapter '$adapterName' on '$switchName'"
        Add-VMNetworkAdapter -VMName $vmName -Name $adapterName -SwitchName $switchName | Out-Null
    } elseif ($adapter.SwitchName -ne $switchName) {
        Log "vm" "Connecting VM management adapter '$adapterName' to '$switchName'"
        Connect-VMNetworkAdapter -VMName $vmName -Name $adapterName -SwitchName $switchName
    } else {
        Log "vm" "VM management adapter '$adapterName' already exists on '$switchName'"
    }

    Set-VMNetworkAdapter -VMName $vmName -Name $adapterName -DeviceNaming On | Out-Null
    Get-VMNetworkAdapter -VMName $vmName -Name $adapterName
}

function ConfigureGuestManagement($cfg, $credential, $adapterMac, $adapterName, $hostIp, $guestIp, $prefixLength, $enableSsh, $enableSunshine, $sunshinePort) {
    Invoke-Command -VMName $cfg.vmName -Credential $credential -ArgumentList $adapterMac, $adapterName, $hostIp, $guestIp, $prefixLength, $enableSsh, $enableSunshine, $sunshinePort -ScriptBlock {
        param($adapterMac, $adapterName, $hostIp, $guestIp, $prefixLength, $enableSsh, $enableSunshine, $sunshinePort)

        function GuestLog($message) {
            Write-Host ("[vm] {0}" -f $message)
        }

        function EnsureScopedFirewallRule($name, $protocol, $ports) {
            $portValues = @($ports | ForEach-Object { [string]$_ })
            $existingRule = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
            if ($existingRule) { Remove-NetFirewallRule -Name $name }
            New-NetFirewallRule `
                -Name $name `
                -DisplayName $name `
                -Direction Inbound `
                -Action Allow `
                -Protocol $protocol `
                -LocalPort $portValues `
                -LocalAddress $guestIp `
                -RemoteAddress $hostIp `
                -InterfaceAlias $adapterName `
                -Profile Any | Out-Null
        }

        $normalized = $adapterMac.Replace("-", "").Replace(":", "")
        $adapter = Get-NetAdapter | Where-Object { $_.MacAddress.Replace("-", "").Replace(":", "") -ieq $normalized } | Select-Object -First 1
        if (-not $adapter) { throw "Guest management adapter with MAC '$adapterMac' was not found." }

        if ($adapter.Name -ne $adapterName) {
            $existing = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
            if ($existing -and $existing.MacAddress.Replace("-", "").Replace(":", "") -ine $normalized) {
                throw "Guest adapter name '$adapterName' is already used by another adapter."
            }
            GuestLog "Renaming guest adapter '$($adapter.Name)' to '$adapterName'"
            Rename-NetAdapter -Name $adapter.Name -NewName $adapterName
        } else {
            GuestLog "Guest adapter '$adapterName' already has the expected name"
        }

        Set-NetIPInterface -InterfaceAlias $adapterName -AddressFamily IPv4 -Dhcp Disabled -Forwarding Disabled -WeakHostReceive Disabled -WeakHostSend Disabled | Out-Null
        Set-DnsClient -InterfaceAlias $adapterName -RegisterThisConnectionsAddress $false -ErrorAction SilentlyContinue | Out-Null
        Set-DnsClientServerAddress -InterfaceAlias $adapterName -ResetServerAddresses -ErrorAction SilentlyContinue | Out-Null

        $defaultRoutes = @(Get-NetRoute -InterfaceAlias $adapterName -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue)
        foreach ($route in $defaultRoutes) {
            GuestLog "Removing default route from $adapterName"
            Remove-NetRoute -InputObject $route -Confirm:$false
        }

        Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne $guestIp -and $_.PrefixOrigin -ne "WellKnown" } |
            ForEach-Object {
                GuestLog "Removing extra IPv4 $($_.IPAddress) from $adapterName"
                Remove-NetIPAddress -InterfaceAlias $adapterName -IPAddress $_.IPAddress -Confirm:$false
            }

        $existingIp = Get-NetIPAddress -InterfaceAlias $adapterName -AddressFamily IPv4 -IPAddress $guestIp -ErrorAction SilentlyContinue
        if (-not $existingIp) {
            GuestLog "Configuring $adapterName = $guestIp/$prefixLength"
            New-NetIPAddress -InterfaceAlias $adapterName -IPAddress $guestIp -PrefixLength $prefixLength -AddressFamily IPv4 | Out-Null
        } else {
            GuestLog "$adapterName already has $guestIp/$prefixLength"
        }

        EnsureScopedFirewallRule "WorkstationVM-Management-RDP-TCP" "TCP" @(3389)
        EnsureScopedFirewallRule "WorkstationVM-Management-RDP-UDP" "UDP" @(3389)
        GuestLog "RDP firewall allows $hostIp -> ${guestIp}:3389 on $adapterName"

        Get-NetFirewallRule -Name "RemoteDesktop-UserMode-In-TCP","RemoteDesktop-UserMode-In-UDP" -ErrorAction SilentlyContinue |
            Set-NetFirewallRule -Enabled False
        GuestLog "Broad default RDP firewall rules are disabled"

        if ($enableSsh) {
            EnsureScopedFirewallRule "WorkstationVM-Management-SSH-TCP" "TCP" @(22)
            Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue |
                Set-NetFirewallRule -Enabled False
            GuestLog "SSH firewall allows $hostIp -> ${guestIp}:22 on $adapterName"
        }

        if ($enableSunshine) {
            $tcpPorts = @(($sunshinePort - 5), $sunshinePort, ($sunshinePort + 1), ($sunshinePort + 21))
            $udpPorts = @(($sunshinePort + 9), ($sunshinePort + 10), ($sunshinePort + 11), ($sunshinePort + 13))
            EnsureScopedFirewallRule "WorkstationVM-Management-Sunshine-TCP" "TCP" $tcpPorts
            EnsureScopedFirewallRule "WorkstationVM-Management-Sunshine-UDP" "UDP" $udpPorts
            Get-NetFirewallRule -Name "WorkstationVM-Sunshine-TCP","WorkstationVM-Sunshine-UDP" -ErrorAction SilentlyContinue |
                Set-NetFirewallRule -Enabled False
            GuestLog "Sunshine firewall allows $hostIp -> ${guestIp} on TCP $($tcpPorts -join ',') and UDP $($udpPorts -join ',')"
        }

        $forwarding = (Get-NetIPInterface -InterfaceAlias $adapterName -AddressFamily IPv4).Forwarding
        $forwardingText = if ($forwarding -eq 0) { "Disabled" } elseif ($forwarding -eq 1) { "Enabled" } else { $forwarding.ToString() }

        [pscustomobject]@{
            Adapter = $adapterName
            GuestIp = $guestIp
            DefaultRouteOnManagement = @(Get-NetRoute -InterfaceAlias $adapterName -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue).Count
            DnsServers = ((Get-DnsClientServerAddress -InterfaceAlias $adapterName -AddressFamily IPv4).ServerAddresses -join ",")
            Forwarding = $forwardingText
        }
    }
}

function EnsureGuestWireGuardAllowsManagement($cfg, $credential) {
    Invoke-Command -VMName $cfg.vmName -Credential $credential -ScriptBlock {
        function GuestLog($message) {
            Write-Host ("[vpn] {0}" -f $message)
        }

        $services = @(Get-CimInstance Win32_Service |
            Where-Object { $_.Name -like "WireGuardTunnel$*" -and $_.State -eq "Running" })
        if ($services.Count -eq 0) {
            GuestLog "No running WireGuard tunnel service was found"
            return
        }

        foreach ($service in $services) {
            if ($service.PathName -notmatch '(?i)/tunnelservice\s+(.+)$') {
                GuestLog "Could not resolve config path for $($service.Name)"
                continue
            }

            $configPath = $Matches[1].Trim().Trim('"')
            if (-not (Test-Path -LiteralPath $configPath)) {
                GuestLog "Config path for $($service.Name) is not accessible"
                continue
            }

            $content = Get-Content -LiteralPath $configPath
            $changed = $false
            $updated = foreach ($line in $content) {
                if ($line -match '^\s*AllowedIPs\s*=\s*(.+)$') {
                    $values = @($Matches[1].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                    if ($values -contains "0.0.0.0/0") {
                        $values = @($values | Where-Object { $_ -ne "0.0.0.0/0" })
                        if ($values -notcontains "0.0.0.0/1") { $values += "0.0.0.0/1" }
                        if ($values -notcontains "128.0.0.0/1") { $values += "128.0.0.0/1" }
                        $changed = $true
                        "AllowedIPs = $($values -join ', ')"
                    } else {
                        $line
                    }
                } else {
                    $line
                }
            }

            if ($changed) {
                $backup = "$configPath.management-backup"
                if (-not (Test-Path -LiteralPath $backup)) {
                    Copy-Item -LiteralPath $configPath -Destination $backup -Force
                }
                Set-Content -LiteralPath $configPath -Value $updated -Encoding ascii
                GuestLog "Converted $($service.Name) from exact 0.0.0.0/0 to split default routes"
                Restart-Service -Name $service.Name -Force
                Start-Sleep -Seconds 3
            } else {
                GuestLog "$($service.Name) already avoids exact 0.0.0.0/0"
            }
        }
    }
}

function WriteRdpFile($cfg, $guestIp) {
    $baseDir = FullPath $cfg.baseDir
    New-Item -ItemType Directory -Force -Path $baseDir | Out-Null
    $path = Join-Path $baseDir "$($cfg.vmName).rdp"

    @(
        "full address:s:${guestIp}:3389",
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

    Log "rdp" "Updated $path"
    return $path
}

$configPath = ArgValue "config" "config\windows.json"
$switchName = ArgValue "switch-name" "WorkstationMgmt"
$adapterName = ArgValue "adapter-name" "Management"
$hostIp = ArgValue "host-ip" "192.168.250.1"
$guestIp = ArgValue "guest-ip" "192.168.250.2"
$prefixLength = [int](ArgValue "prefix-length" "24")
$subnetPrefix = "$(($hostIp -replace '\.\d+$','.0'))/$prefixLength"
$skipWireGuardRouteFix = Flag "skip-wireguard-route-fix"

$cfg = Get-Content -Raw (FullPath $configPath) | ConvertFrom-Json
@{
    vmName = "WorkstationW11"
    user = "work"
    baseDir = "~/VMs/WorkstationWindows11"
    sshEnabled = $true
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }
$streaming = ChildConfig $cfg "remoteStreaming"
Default $streaming "enabled" $false
Default $streaming "installSunshine" $true
Default $streaming "port" 47989

AssertAdministrator

Write-Host "Configuring private management network for VM '$($cfg.vmName)'"
Write-Host "No NAT, gateway, DNS or IP forwarding will be configured for this network."
Write-Host ""

AssertNoSubnetNat $subnetPrefix
EnsureInternalSwitch $switchName | Out-Null
$hostAlias = EnsureHostAddress $switchName $hostIp $prefixLength
$vmAdapter = EnsureVmAdapter $cfg.vmName $switchName $adapterName
$credential = GuestCredential $cfg
$enableSunshine = [bool]$streaming.enabled -and [bool]$streaming.installSunshine
$guestState = ConfigureGuestManagement $cfg $credential $vmAdapter.MacAddress $adapterName $hostIp $guestIp $prefixLength ([bool]$cfg.sshEnabled) $enableSunshine ([int]$streaming.port)
if ($skipWireGuardRouteFix) {
    Log "vpn" "WireGuard route fix was skipped by request"
} else {
    EnsureGuestWireGuardAllowsManagement $cfg $credential
}
$rdpPath = WriteRdpFile $cfg $guestIp

$hostDefaultRoutes = @(Get-NetRoute -InterfaceAlias $hostAlias -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue)
$hostDns = ((Get-DnsClientServerAddress -InterfaceAlias $hostAlias -AddressFamily IPv4).ServerAddresses -join ",")
$hostForwarding = (Get-NetIPInterface -InterfaceAlias $hostAlias -AddressFamily IPv4).Forwarding
$rdpTcp = Test-NetConnection -ComputerName $guestIp -Port 3389 -InformationLevel Quiet
$sshTcp = if ([bool]$cfg.sshEnabled) { Test-NetConnection -ComputerName $guestIp -Port 22 -InformationLevel Quiet } else { $true }
$sunshineWebTcp = if ($enableSunshine) { Test-NetConnection -ComputerName $guestIp -Port ([int]$streaming.port + 1) -InformationLevel Quiet } else { $true }

Write-Host ""
Log "host" "Management interface: $hostAlias $hostIp/$prefixLength"
Log "host" "Default routes on management interface: $($hostDefaultRoutes.Count)"
Log "host" "DNS servers on management interface: $hostDns"
Log "host" "IP forwarding on management interface: $hostForwarding"
Log "vm" "Management interface: $adapterName $guestIp/$prefixLength"
Log "vm" "Default routes on management interface: $($guestState.DefaultRouteOnManagement)"
Log "vm" "DNS servers on management interface: $($guestState.DnsServers)"
Log "vm" "IP forwarding on management interface: $($guestState.Forwarding)"
Log "test" "RDP TCP ${guestIp}:3389 reachable: $rdpTcp"
if ([bool]$cfg.sshEnabled) { Log "test" "SSH TCP ${guestIp}:22 reachable: $sshTcp" }
if ($enableSunshine) { Log "test" "Sunshine Web UI TCP ${guestIp}:$([int]$streaming.port + 1) reachable: $sunshineWebTcp" }

if ($hostDefaultRoutes.Count -ne 0) { throw "Host management interface has a default route. Refusing unsafe configuration." }
if (-not [string]::IsNullOrWhiteSpace($hostDns)) { throw "Host management interface has DNS servers. Refusing unsafe configuration." }
if ($hostForwarding -ne "Disabled") { throw "Host management interface has IP forwarding enabled. Refusing unsafe configuration." }
if ($guestState.DefaultRouteOnManagement -ne 0) { throw "Guest management interface has a default route. Refusing unsafe configuration." }
if (-not [string]::IsNullOrWhiteSpace($guestState.DnsServers)) { throw "Guest management interface has DNS servers. Refusing unsafe configuration." }
if ($guestState.Forwarding -ne "Disabled") { throw "Guest management interface has IP forwarding enabled. Refusing unsafe configuration." }
if (-not $rdpTcp) { throw "RDP was not reachable on ${guestIp}:3389." }
if (-not $sshTcp) { throw "SSH was not reachable on ${guestIp}:22." }
if (-not $sunshineWebTcp) { throw "Sunshine Web UI was not reachable on ${guestIp}:$([int]$streaming.port + 1)." }

Write-Host ""
Write-Host "READY: private management network is configured."
