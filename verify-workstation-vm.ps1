param(
    [ValidateSet("Ubuntu", "Windows11")]
    [string]$Variant = "Ubuntu",
    [string]$ConfigRoot = "",
    [string]$LocalConfigPath = "",
    [string]$VMName = "",
    [string]$SshHost = "",
    [string]$ExpectedSwitchName = "",
    [int]$ExpectedCpuCount = 0,
    [int]$ExpectedMemoryGiB = 0,
    [ValidateSet("", "Full", "Smoke")]
    [string]$ProvisioningProfile = "",
    [int]$TimeoutMinutes = 45
)

$ErrorActionPreference = "Stop"

function Expand-ConfigPathValue([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -match '^~[\\/](.*)$') {
        return (Join-Path $HOME $Matches[1])
    }
    return $expanded
}

function Resolve-RepoPath {
    param(
        [string]$Path,
        [string]$DefaultRelativePath
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($Path)) { $DefaultRelativePath } else { $Path }
    $candidate = Expand-ConfigPathValue $candidate
    if ([System.IO.Path]::IsPathRooted($candidate)) {
        return $candidate
    }
    return (Join-Path $PSScriptRoot $candidate)
}

function Import-WorkstationConfig {
    param(
        [string]$Root,
        [string]$Variant,
        [string]$LocalPath
    )

    $configRoot = Resolve-RepoPath -Path $Root -DefaultRelativePath "config"
    $variantFileName = switch ($Variant) {
        "Ubuntu" { "ubuntu.psd1" }
        "Windows11" { "windows11.psd1" }
        default { throw "Variant must be Ubuntu or Windows11. Current value: $Variant" }
    }

    $paths = @(
        (Join-Path $configRoot "common.psd1"),
        (Join-Path $configRoot $variantFileName)
    )

    $local = Resolve-RepoPath -Path $LocalPath -DefaultRelativePath "config\local.psd1"
    if (Test-Path $local) {
        $paths += $local
    }

    $config = @{}
    foreach ($path in $paths) {
        if (-not (Test-Path $path)) {
            throw "Config file not found: $path"
        }
        $fileConfig = Import-PowerShellDataFile -Path $path
        foreach ($key in $fileConfig.Keys) {
            $config[$key] = $fileConfig[$key]
        }
    }

    $config.Variant = $Variant
    return $config
}

$config = Import-WorkstationConfig -Root $ConfigRoot -Variant $Variant -LocalPath $LocalConfigPath
if ($PSBoundParameters.ContainsKey("VMName")) { $config.VMName = $VMName }
if ($PSBoundParameters.ContainsKey("SshHost")) { $config.MaintenanceSshHost = $SshHost }
if ($PSBoundParameters.ContainsKey("ExpectedSwitchName")) { $config.SwitchName = $ExpectedSwitchName }
if ($PSBoundParameters.ContainsKey("ExpectedCpuCount")) { $config.CpuCount = $ExpectedCpuCount }
if ($PSBoundParameters.ContainsKey("ExpectedMemoryGiB")) { $config.MemoryStartupGB = $ExpectedMemoryGiB }
if ($PSBoundParameters.ContainsKey("ProvisioningProfile") -and -not [string]::IsNullOrWhiteSpace($ProvisioningProfile)) { $config.ProvisioningProfile = $ProvisioningProfile }
if ([string]::IsNullOrWhiteSpace([string]$config.ProvisioningProfile)) { $config.ProvisioningProfile = "Full" }

$results = New-Object System.Collections.Generic.List[object]

function Add-Check([string]$Name, [bool]$Ok, [string]$Details) {
    $script:results.Add([pscustomobject]@{
        Check = $Name
        OK = $Ok
        Details = $Details
    }) | Out-Null
}

function Get-GeneratedPassword {
    param([hashtable]$Config)

    if (-not [string]::IsNullOrWhiteSpace($Config.Password)) {
        return [string]$Config.Password
    }

    $passwordPaths = @(
        (Join-Path $PSScriptRoot ("{0}_password.txt" -f $Config.VMName)),
        (Join-Path $PSScriptRoot "workstation_vm_password.txt")
    )

    $passwordPath = $passwordPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $passwordPath) {
        return ""
    }

    foreach ($line in (Get-Content -LiteralPath $passwordPath)) {
        if ($line -match '^Password:\s*(.+)$') {
            return $Matches[1]
        }
    }
    return ""
}

$vm = Get-VM -Name $config.VMName -ErrorAction SilentlyContinue
Add-Check "VM exists" ($null -ne $vm) ([string]$config.VMName)

if ($vm) {
    Add-Check "VM running" ($vm.State -eq "Running") ("State={0}" -f $vm.State)
    Add-Check "vCPU count" ($vm.ProcessorCount -eq [int]$config.CpuCount) ("ProcessorCount={0}" -f $vm.ProcessorCount)
    Add-Check "Static memory" (-not $vm.DynamicMemoryEnabled) ("DynamicMemoryEnabled={0}" -f $vm.DynamicMemoryEnabled)
    Add-Check "Memory assigned" ($vm.MemoryAssigned -ge ([int]$config.MemoryStartupGB * 1GB)) ("MemoryAssignedGiB={0:N2}" -f ($vm.MemoryAssigned / 1GB))
    Add-Check "Manual checkpoints enabled" ($vm.CheckpointType -ne "Disabled" -and -not $vm.AutomaticCheckpointsEnabled) ("CheckpointType={0}; Automatic={1}" -f $vm.CheckpointType, $vm.AutomaticCheckpointsEnabled)

    $adapter = Get-VMNetworkAdapter -VMName $config.VMName
    Add-Check "Expected switch" ($adapter.SwitchName -eq [string]$config.SwitchName) ("SwitchName={0}" -f $adapter.SwitchName)
    Add-Check "DHCP guard enabled" ($adapter.DhcpGuard -eq "On") ("DhcpGuard={0}" -f $adapter.DhcpGuard)
    Add-Check "Router guard enabled" ($adapter.RouterGuard -eq "On") ("RouterGuard={0}" -f $adapter.RouterGuard)
    Add-Check "MAC spoofing disabled" ($adapter.MacAddressSpoofing -eq "Off") ("MacAddressSpoofing={0}" -f $adapter.MacAddressSpoofing)

    $guestService = Get-VMIntegrationService -VMName $config.VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
    Add-Check "Host file-copy service disabled" ($guestService -and -not $guestService.Enabled) ("GuestServiceEnabled={0}" -f $guestService.Enabled)
}

if ($vm -and $vm.State -eq "Running" -and $config.Variant -eq "Ubuntu") {
    if ([string]::IsNullOrWhiteSpace($SshHost)) {
        $SshHost = [string]$config.MaintenanceSshHost
    }
    if ([string]::IsNullOrWhiteSpace($SshHost)) {
        $SshHost = [string]$config.HostName
    }
    $sshConfigOutput = & ssh -G $SshHost 2>$null
    $tcpHost = $SshHost
    foreach ($line in $sshConfigOutput) {
        if ($line -match "^hostname\s+(.+)$") {
            $tcpHost = $Matches[1]
            break
        }
    }

    Add-Check "SSH host resolved" (-not [string]::IsNullOrWhiteSpace($tcpHost)) ("{0} -> {1}" -f $SshHost, $tcpHost)
    $sshTarget = $SshHost
    if ($sshTarget -notmatch "@" -and -not [string]::IsNullOrWhiteSpace([string]$config.VMUser)) {
        $sshTarget = "{0}@{1}" -f $config.VMUser, $SshHost
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $tcp = $false
    while ((Get-Date) -lt $deadline) {
        $tcp = Test-NetConnection $tcpHost -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($tcp) {
            break
        }
        Start-Sleep -Seconds 10
    }
    Add-Check "SSH reachable" $tcp ("Host={0}:22" -f $tcpHost)
    $rdp = Test-NetConnection $tcpHost -Port 3389 -InformationLevel Quiet -WarningAction SilentlyContinue
    Add-Check "RDP port closed" (-not $rdp) ("Host={0}:3389 reachable={1}" -f $tcpHost, $rdp)

    if ($tcp) {
        $remoteScript = @'
set +e
user="$1"
echo "hostname=$(hostname)"
echo "nproc=$(nproc)"
awk '/MemTotal/ {print "mem_kib="$2}' /proc/meminfo
echo "ssh_service=$(systemctl is-active ssh 2>/dev/null)"
echo "lightdm_service=$(systemctl is-active lightdm 2>/dev/null)"
echo "xrdp_package_count=$(dpkg-query -W -f='${binary:Package}\n' xrdp xorgxrdp 2>/dev/null | wc -l)"
echo "port_3389_listener_count=$(ss -ltnH 'sport = :3389' 2>/dev/null | wc -l)"
echo "edge_path=$(command -v microsoft-edge-stable 2>/dev/null)"
echo "code_path=$(command -v code 2>/dev/null)"
echo "wireguard_path=$(command -v wg 2>/dev/null)"
echo "rg_path=$(command -v rg 2>/dev/null)"
echo "jq_path=$(command -v jq 2>/dev/null)"
echo "fzf_path=$(command -v fzf 2>/dev/null)"
echo "wg_interfaces=$(sudo -n wg show interfaces 2>/dev/null)"
echo "lightdm_autologin_user=$(grep -E '^autologin-user=' /etc/lightdm/lightdm.conf.d/50-workstation-autologin.conf 2>/dev/null | tail -n1 | cut -d= -f2)"
echo "lightdm_session=$(grep -E '^user-session=' /etc/lightdm/lightdm.conf.d/50-workstation-autologin.conf 2>/dev/null | tail -n1 | cut -d= -f2)"
id -nG "$user" | tr ' ' '\n' | grep -qx nopasswdlogin
echo "nopasswdlogin_member=$?"
echo "dmrc_session=$(grep -E '^Session=' "/home/$user/.dmrc" 2>/dev/null | tail -n1 | cut -d= -f2)"
echo "console_session_count=$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$user" '$3==u && $4=="seat0" {count++} END {print count+0}')"
echo "hyperv_drm_loaded=$(lsmod | awk '$1=="hyperv_drm" {print 1; found=1} END {if(!found) print 0}')"
echo "display_refresh_hz=$(sudo -u "$user" env DISPLAY=:0 XAUTHORITY="/home/$user/.Xauthority" xrandr --query 2>/dev/null | awk '/\*/{for(i=1;i<=NF;i++) if($i ~ /\*/) {gsub("[*+]", "", $i); print $i; exit}}')"
echo "display_mode=$(sudo -u "$user" env DISPLAY=:0 XAUTHORITY="/home/$user/.Xauthority" xrandr --query 2>/dev/null | awk '/\*/{print $1; exit}')"
echo "display_120hz_daemon_count=$(pgrep -u "$user" -f '/usr/local/bin/workstation-set-display-120hz' 2>/dev/null | wc -l)"
echo "remote_ssh_extension_count=$(find "/home/$user/.vscode/extensions" -maxdepth 1 -type d -name 'ms-vscode-remote.remote-ssh-*' 2>/dev/null | wc -l)"
test -x "/home/$user/Desktop/Work-Apps.desktop"
echo "work_apps_launcher=$?"
test -x "/home/$user/Desktop/VS-Code.desktop"
echo "vscode_launcher=$?"
test -x "/home/$user/Desktop/Terminal.desktop"
echo "terminal_launcher=$?"
cloud_status=$(cloud-init status 2>/dev/null | sed 's/^status: //')
echo "cloud_init_status=$cloud_status"
test -d "/home/$user/Work"
echo "work_dir=$?"
'@

        $sshOptions = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new")
        $sshIdentityPath = Join-Path $env:USERPROFILE ".ssh\workstation_jump_ed25519"
        if (Test-Path $sshIdentityPath) {
            $sshOptions += @("-i", $sshIdentityPath, "-o", "IdentitiesOnly=yes")
        }

        $remoteOutput = ""
        $sshExit = 255
        while ((Get-Date) -lt $deadline) {
            $remoteOutput = $remoteScript | & ssh @sshOptions $sshTarget "bash -s -- '$($config.VMUser)'" 2>&1
            $sshExit = $LASTEXITCODE
            if ($sshExit -eq 0) {
                break
            }
            Start-Sleep -Seconds 10
        }
        Add-Check "SSH command execution" ($sshExit -eq 0) ("Target={0}; ExitCode={1}" -f $sshTarget, $sshExit)

        if ($sshExit -eq 0) {
            $remote = @{}
            foreach ($line in ($remoteOutput -split "`r?`n")) {
                if ($line -match "^([^=]+)=(.*)$") {
                    $remote[$Matches[1]] = $Matches[2]
                }
            }

            $minLinuxMemKiB = [int64]([int]$config.MemoryStartupGB * 1024 * 1024 * 0.90)
            $memKiB = [int64]($remote["mem_kib"])
            Add-Check "Linux CPU count" ([int]$remote["nproc"] -eq [int]$config.CpuCount) ("nproc={0}" -f $remote["nproc"])
            Add-Check "Linux memory visible" ($memKiB -ge $minLinuxMemKiB) ("MemTotalKiB={0}" -f $memKiB)
            Add-Check "cloud-init completed" ($remote["cloud_init_status"] -eq "done") ("cloud-init={0}" -f $remote["cloud_init_status"])
            Add-Check "SSH service active" ($remote["ssh_service"] -eq "active") ("ssh={0}" -f $remote["ssh_service"])
            Add-Check "No RDP listener in VM" ([int]$remote["port_3389_listener_count"] -eq 0) ("port_3389_listener_count={0}" -f $remote["port_3389_listener_count"])
            Add-Check "No active WireGuard tunnel" ([string]::IsNullOrWhiteSpace($remote["wg_interfaces"])) ("wg_interfaces={0}" -f $remote["wg_interfaces"])
            Add-Check "Work directory exists" ($remote["work_dir"] -eq "0") ("work_dir={0}" -f $remote["work_dir"])

            if ($config.ProvisioningProfile -ne "Smoke") {
                Add-Check "LightDM service active" ($remote["lightdm_service"] -eq "active") ("lightdm={0}" -f $remote["lightdm_service"])
                Add-Check "XRDP packages removed" ([int]$remote["xrdp_package_count"] -eq 0) ("xrdp_package_count={0}" -f $remote["xrdp_package_count"])
                Add-Check "Edge installed" (-not [string]::IsNullOrWhiteSpace($remote["edge_path"])) $remote["edge_path"]
                Add-Check "VS Code installed" (-not [string]::IsNullOrWhiteSpace($remote["code_path"])) $remote["code_path"]
                Add-Check "WireGuard tools installed" (-not [string]::IsNullOrWhiteSpace($remote["wireguard_path"])) $remote["wireguard_path"]
                Add-Check "Workstation CLI tools installed" (-not [string]::IsNullOrWhiteSpace($remote["rg_path"]) -and -not [string]::IsNullOrWhiteSpace($remote["jq_path"]) -and -not [string]::IsNullOrWhiteSpace($remote["fzf_path"])) ("rg={0}; jq={1}; fzf={2}" -f $remote["rg_path"], $remote["jq_path"], $remote["fzf_path"])
                Add-Check "Hyper-V console autologin user" ($remote["lightdm_autologin_user"] -eq [string]$config.VMUser) ("autologin-user={0}" -f $remote["lightdm_autologin_user"])
                Add-Check "Hyper-V console session" ($remote["lightdm_session"] -eq "xfce") ("user-session={0}" -f $remote["lightdm_session"])
                Add-Check "User allowed for LightDM autologin" ($remote["nopasswdlogin_member"] -eq "0") ("nopasswdlogin_member={0}" -f $remote["nopasswdlogin_member"])
                Add-Check "User default desktop session" ($remote["dmrc_session"] -eq "xfce") ("dmrc_session={0}" -f $remote["dmrc_session"])
                Add-Check "Hyper-V console desktop active" ([int]$remote["console_session_count"] -ge 1) ("console_session_count={0}" -f $remote["console_session_count"])
                Add-Check "Hyper-V DRM display driver active" ([int]$remote["hyperv_drm_loaded"] -eq 1) ("hyperv_drm_loaded={0}" -f $remote["hyperv_drm_loaded"])
                Add-Check "Hyper-V display refresh >=110Hz" ([double]$remote["display_refresh_hz"] -ge 110.0) ("{0} {1}Hz" -f $remote["display_mode"], $remote["display_refresh_hz"])
                Add-Check "Display refresh daemon active" ([int]$remote["display_120hz_daemon_count"] -ge 1) ("display_120hz_daemon_count={0}" -f $remote["display_120hz_daemon_count"])
                Add-Check "VS Code Remote SSH installed" ([int]$remote["remote_ssh_extension_count"] -ge 1) ("remote_ssh_extension_count={0}" -f $remote["remote_ssh_extension_count"])
                Add-Check "Desktop launchers installed" ($remote["work_apps_launcher"] -eq "0" -and $remote["vscode_launcher"] -eq "0" -and $remote["terminal_launcher"] -eq "0") ("work_apps={0}; vscode={1}; terminal={2}" -f $remote["work_apps_launcher"], $remote["vscode_launcher"], $remote["terminal_launcher"])
            }
        }
    }
}

if ($vm -and $vm.State -eq "Running" -and $config.Variant -eq "Windows11") {
    $password = Get-GeneratedPassword -Config $config
    Add-Check "Windows local password available" (-not [string]::IsNullOrWhiteSpace($password)) "config or generated password file"

    if (-not [string]::IsNullOrWhiteSpace($password)) {
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $credential = [pscredential]::new(([string]$config.VMUser), $securePassword)

        try {
            $guest = $null
            $lastError = $null
            $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
            while ((Get-Date) -lt $deadline -and -not $guest) {
                try {
                    $guest = Invoke-Command -VMName $config.VMName -Credential $credential -ScriptBlock {
                $computer = Get-CimInstance Win32_ComputerSystem
                $os = Get-CimInstance Win32_OperatingSystem
                $desktop = [Environment]::GetFolderPath("Desktop")
                $edge1 = "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe"
                $edge2 = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
                $code1 = "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
                $code2 = "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
                $rdpSetting = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -ErrorAction SilentlyContinue
                [pscustomobject]@{
                    os_caption = $os.Caption
                    cpu_count = $computer.NumberOfLogicalProcessors
                    memory_bytes = [int64]$computer.TotalPhysicalMemory
                    provisioned = Test-Path C:\WorkstationVm\provisioned.txt
                    edge = (Test-Path $edge1) -or (Test-Path $edge2)
                    code = (Test-Path $code1) -or (Test-Path $code2)
                    git = $null -ne (Get-Command git.exe -ErrorAction SilentlyContinue)
                    rg = $null -ne (Get-Command rg.exe -ErrorAction SilentlyContinue)
                    jq = $null -ne (Get-Command jq.exe -ErrorAction SilentlyContinue)
                    wireguard = Test-Path "$env:ProgramFiles\WireGuard\wireguard.exe"
                    active_wireguard_count = @((Get-NetAdapter -InterfaceDescription "*WireGuard*" -ErrorAction SilentlyContinue) | Where-Object { $_.Status -eq "Up" }).Count
                    rdp_denied = [int]$rdpSetting.fDenyTSConnections
                    rdp_firewall_enabled_count = @(Get-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq "True" }).Count
                    fps_check = Test-Path C:\WorkstationVm\fps-check.html
                    work_apps_shortcut = Test-Path (Join-Path $desktop "Work Apps.lnk")
                    fps_shortcut = Test-Path (Join-Path $desktop "FPS Check.lnk")
                    vscode_shortcut = Test-Path (Join-Path $desktop "VS Code.lnk")
                    powershell_shortcut = Test-Path (Join-Path $desktop "PowerShell.lnk")
                }
                    } -ErrorAction Stop
                } catch {
                    $lastError = $_
                    Start-Sleep -Seconds 20
                }
            }

            if (-not $guest) {
                throw $lastError
            }

            Add-Check "PowerShell Direct works" $true "guest reachable"
            Add-Check "Windows 11 installed" ($guest.os_caption -like "*Windows 11*") $guest.os_caption
            Add-Check "Windows CPU count" ([int]$guest.cpu_count -eq [int]$config.CpuCount) ("cpu_count={0}" -f $guest.cpu_count)
            Add-Check "Windows memory visible" ([int64]$guest.memory_bytes -ge ([int]$config.MemoryStartupGB * 1GB * 0.85)) ("memoryGiB={0:N2}" -f ([int64]$guest.memory_bytes / 1GB))
            Add-Check "No active WireGuard tunnel" ([int]$guest.active_wireguard_count -eq 0) ("active_wireguard_count={0}" -f $guest.active_wireguard_count)
            Add-Check "Network RDP disabled" ([int]$guest.rdp_denied -eq 1 -and [int]$guest.rdp_firewall_enabled_count -eq 0) ("rdp_denied={0}; firewall_enabled={1}" -f $guest.rdp_denied, $guest.rdp_firewall_enabled_count)
            if ($config.ProvisioningProfile -ne "Smoke") {
                Add-Check "Guest provisioning completed" ([bool]$guest.provisioned) "C:\WorkstationVm\provisioned.txt"
                Add-Check "Edge installed" ([bool]$guest.edge) "Microsoft Edge"
                Add-Check "VS Code installed" ([bool]$guest.code) "Visual Studio Code"
                Add-Check "Git installed" ([bool]$guest.git) "git.exe"
                Add-Check "CLI tools installed" ([bool]$guest.rg -and [bool]$guest.jq) ("rg={0}; jq={1}" -f $guest.rg, $guest.jq)
                Add-Check "WireGuard installed" ([bool]$guest.wireguard) "WireGuard"
                Add-Check "FPS check page installed" ([bool]$guest.fps_check) "C:\WorkstationVm\fps-check.html"
                Add-Check "Desktop shortcuts installed" ([bool]$guest.work_apps_shortcut -and [bool]$guest.fps_shortcut -and [bool]$guest.vscode_shortcut -and [bool]$guest.powershell_shortcut) ("work_apps={0}; fps={1}; vscode={2}; powershell={3}" -f $guest.work_apps_shortcut, $guest.fps_shortcut, $guest.vscode_shortcut, $guest.powershell_shortcut)
            }
        } catch {
            Add-Check "PowerShell Direct works" $false $_.Exception.Message
        }
    }
}

$results | Format-Table -AutoSize
if (($results | Where-Object { -not $_.OK }).Count -gt 0) {
    exit 1
}
