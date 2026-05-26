param(
    [ValidateSet("Ubuntu", "Windows11")]
    [string]$Variant = "Ubuntu",
    [string]$ConfigRoot = "",
    [string]$LocalConfigPath = "",
    [string]$VMName = "",
    [string]$BaseDir = "",
    [string]$VMUser = "",
    [string]$PlainPassword = "",
    [string]$SwitchName = "",
    [string]$ImageCacheRoot = "",
    [ValidateSet("", "Full", "Smoke")]
    [string]$ProvisioningProfile = "",
    [int64]$MemoryStartupBytes = 0,
    [int64]$VhdSizeBytes = 0,
    [int]$CpuCount = 0,
    [int]$DisplayWidth = 0,
    [int]$DisplayHeight = 0,
    [int]$DisplayRefresh = 0,
    [string]$WindowsIsoPath = "",
    [string]$WindowsRelease = "",
    [string]$WindowsEdition = "",
    [string]$WindowsLanguage = "",
    [string]$WindowsArch = "",
    [string]$WindowsImageName = "",
    [string]$FidoUrl = "",
    [int]$WindowsImageIndex = 0,
    [switch]$SkipGuestProvisioning,
    [switch]$SkipCleanCheckpoint
)

$ErrorActionPreference = "Stop"

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Get-AvailableCommand([string[]]$Names) {
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command
        }
    }
    return $null
}

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

function Convert-ToWslPath([string]$Path) {
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Cannot convert non-drive Windows path to WSL path: $Path"
    }
    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2] -replace '\\', '/'
    return "/mnt/$drive/$rest"
}

function New-RandomPassword {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return [Convert]::ToBase64String($bytes).TrimEnd("=") -replace "[+/]", "x"
}

function ConvertTo-XmlText([string]$Value) {
    return [System.Security.SecurityElement]::Escape($Value)
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
    $config.ConfigRoot = $configRoot
    $config.LocalConfigPath = $local
    return $config
}

function Set-Override {
    param(
        [hashtable]$Config,
        [string]$Key,
        [object]$Value,
        [bool]$WasProvided
    )

    if ($WasProvided) {
        $Config[$Key] = $Value
    }
}

function New-WorkstationPaths {
    param([hashtable]$Config)

    $baseDir = Expand-ConfigPathValue ([string]$Config.BaseDir)
    $imageCacheRoot = Expand-ConfigPathValue ([string]$Config.ImageCacheRoot)
    if ([string]::IsNullOrWhiteSpace($imageCacheRoot)) {
        $imageCacheRoot = Join-Path (Split-Path -Parent $baseDir) "_image-cache"
    }
    $linuxImageDir = Join-Path $imageCacheRoot "linux"
    $windowsImageDir = Join-Path $imageCacheRoot "windows"
    $seedDir = Join-Path $baseDir "seed"
    $vmDir = Join-Path $baseDir "vm"
    $variant = ([string]$Config.Variant).ToLowerInvariant()
    $vhdPath = Join-Path $vmDir ("{0}.vhdx" -f $Config.VMName)

    [pscustomobject]@{
        BaseDir = $baseDir
        ImageCacheRoot = $imageCacheRoot
        LinuxImageDir = $linuxImageDir
        WindowsImageDir = $windowsImageDir
        SeedDir = $seedDir
        VmDir = $vmDir
        VhdPath = $vhdPath
        UbuntuImagePath = Join-Path $linuxImageDir "ubuntu-24.04-server-cloudimg-amd64.img"
        FidoPath = Join-Path $windowsImageDir "Fido.ps1"
        SeedIsoPath = Join-Path $vmDir ("{0}-seed.iso" -f $Config.VMName)
        AnswerIsoPath = Join-Path $vmDir ("{0}-autounattend.iso" -f $Config.VMName)
        PasswordPath = Join-Path $PSScriptRoot ("{0}_password.txt" -f $Config.VMName)
        SshKeyPath = Join-Path $env:USERPROFILE ".ssh\workstation_jump_ed25519"
        Variant = $variant
    }
}

function Write-PasswordFile {
    param(
        [string]$Path,
        [string]$Variant,
        [string]$User,
        [string]$Password
    )

    Set-Content -LiteralPath $Path -Value @"
Workstation VM local login

Variant: $Variant
User: $User
Password: $Password

Use this only for the local VM login and provisioning. Do not store customer credentials here.
"@ -Encoding ASCII
    icacls.exe $Path /inheritance:r /grant:r "$env:USERNAME`:F" | Out-Null
}

function Assert-CommonPreconditions {
    param([hashtable]$Config)

    Require-Command New-VM
    if (-not (Get-AvailableCommand @("oscdimg", "mkisofs", "genisoimage"))) {
        throw "Required ISO creation command not found. Install oscdimg, mkisofs, or genisoimage."
    }

    $switch = Get-VMSwitch -Name $Config.SwitchName -ErrorAction SilentlyContinue
    if (-not $switch) {
        throw "Hyper-V switch not found: $($Config.SwitchName)"
    }

    if (Get-VM -Name $Config.VMName -ErrorAction SilentlyContinue) {
        throw "VM already exists: $($Config.VMName)"
    }
}

function Set-WorkstationVmHardwareBaseline {
    param(
        [hashtable]$Config,
        [string]$VhdPath,
        [string]$SecureBootTemplate
    )

    New-VM -Name $Config.VMName `
        -Generation 2 `
        -MemoryStartupBytes ([int64]$Config.MemoryStartupBytes) `
        -VHDPath $VhdPath `
        -Path (Join-Path $Config.Paths.VmDir $Config.VMName) `
        -SwitchName $Config.SwitchName | Out-Null

    Set-VMProcessor -VMName $Config.VMName -Count ([int]$Config.CpuCount)
    Set-VMMemory -VMName $Config.VMName -DynamicMemoryEnabled $false -StartupBytes ([int64]$Config.MemoryStartupBytes)
    Set-VMFirmware -VMName $Config.VMName -EnableSecureBoot On -SecureBootTemplate $SecureBootTemplate
    Set-VM -Name $Config.VMName -CheckpointType Standard -AutomaticCheckpointsEnabled $false
    Set-VMNetworkAdapter -VMName $Config.VMName -DhcpGuard On -RouterGuard On -MacAddressSpoofing Off
    Disable-VMIntegrationService -VMName $Config.VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
}

function New-IsoFromDirectory {
    param(
        [string]$SourceDir,
        [string]$IsoPath,
        [string]$Label
    )

    if (Test-Path $IsoPath) {
        Remove-Item -LiteralPath $IsoPath -Force
    }

    if (Get-Command oscdimg -ErrorAction SilentlyContinue) {
        oscdimg.exe -j2 "-l$Label" $SourceDir $IsoPath | Out-Null
        return
    }

    $mkisofs = Get-AvailableCommand @("mkisofs", "genisoimage")
    if ($mkisofs) {
        & $mkisofs.Source -quiet -J -R -V $Label -o $IsoPath $SourceDir
        if ($LASTEXITCODE -ne 0) {
            throw "$($mkisofs.Name) failed with exit code $LASTEXITCODE"
        }
        return
    }

    throw "Required ISO creation command not found. Install oscdimg, mkisofs, or genisoimage."
}

function Clear-VirtualDiskHostAttributes {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    attrib.exe -C -E $resolvedPath | Out-Null
    fsutil.exe sparse setflag $resolvedPath 0 | Out-Null
}

function New-UbuntuNetworkConfig {
    param([hashtable]$Config)

    if (-not $Config.ContainsKey("UbuntuStaticAddress") -or [string]::IsNullOrWhiteSpace([string]$Config.UbuntuStaticAddress)) {
        return ""
    }

    $gateway = [string]$Config.UbuntuGateway
    if ([string]::IsNullOrWhiteSpace($gateway)) {
        throw "UbuntuGateway must be set when UbuntuStaticAddress is set."
    }

    $dnsServers = @($Config.UbuntuDnsServers) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    if ($dnsServers.Count -eq 0) {
        $dnsServers = @($gateway)
    }
    $dnsYaml = ($dnsServers | ForEach-Object { "        - $_" }) -join "`n"

    @"
version: 2
ethernets:
  primary:
    match:
      name: "e*"
    dhcp4: false
    addresses:
      - $($Config.UbuntuStaticAddress)
    routes:
      - to: default
        via: $gateway
    nameservers:
      addresses:
$dnsYaml
"@
}

function Ensure-UbuntuSshKey {
    param([hashtable]$Config)

    Require-Command ssh-keygen
    $keyPath = $Config.Paths.SshKeyPath
    $publicKeyPath = "$keyPath.pub"

    if (-not (Test-Path $publicKeyPath)) {
        $keyDir = Split-Path -Parent $keyPath
        New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
        $sshKeygenCommand = 'ssh-keygen.exe -q -t ed25519 -f "' + $keyPath + '" -N "" -C "workstation-vm-local-vm"'
        cmd.exe /c $sshKeygenCommand
        if ($LASTEXITCODE -ne 0) {
            throw "ssh-keygen failed with exit code $LASTEXITCODE"
        }
    }

    $publicKey = (Get-Content -Raw $publicKeyPath).Trim()
    if (-not $publicKey.StartsWith("ssh-")) {
        throw "Invalid public key at $publicKeyPath"
    }

    $Config.SshPublicKeyPath = $publicKeyPath
    $Config.SshPublicKey = $publicKey
}

function New-UbuntuVhd {
    param([hashtable]$Config)

    Require-Command curl

    if (-not (Test-Path $Config.Paths.UbuntuImagePath)) {
        curl.exe -L --fail --output $Config.Paths.UbuntuImagePath ([string]$Config.UbuntuImageUrl)
    }

    $actualSha256 = (Get-FileHash -Algorithm SHA256 $Config.Paths.UbuntuImagePath).Hash.ToLowerInvariant()
    $expectedSha256 = ([string]$Config.UbuntuImageSha256).ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw "SHA256 mismatch for $($Config.Paths.UbuntuImagePath). Expected $expectedSha256 but got $actualSha256"
    }

    if (Test-Path $Config.Paths.VhdPath) {
        Remove-Item -LiteralPath $Config.Paths.VhdPath -Force
    }

    $qemuImg = Get-AvailableCommand @("qemu-img", "qemu-img.exe")
    if ($qemuImg) {
        & $qemuImg.Source convert -p -O vhdx -o subformat=dynamic $Config.Paths.UbuntuImagePath $Config.Paths.VhdPath
        if ($LASTEXITCODE -ne 0) {
            throw "qemu-img conversion failed with exit code $LASTEXITCODE"
        }
    } else {
        Require-Command wsl
        $sourceWslPath = Convert-ToWslPath $Config.Paths.UbuntuImagePath
        $destWslPath = Convert-ToWslPath $Config.Paths.VhdPath
        wsl.exe -d Ubuntu-24.04 -- qemu-img convert -p -O vhdx -o subformat=dynamic $sourceWslPath $destWslPath
        if ($LASTEXITCODE -ne 0) {
            throw "qemu-img conversion failed with exit code $LASTEXITCODE"
        }
    }
    Clear-VirtualDiskHostAttributes -Path $Config.Paths.VhdPath
    Resize-VHD -Path $Config.Paths.VhdPath -SizeBytes ([int64]$Config.VhdSizeBytes)
}

function New-UbuntuSeedIso {
    param([hashtable]$Config)

    $seedDir = $Config.Paths.SeedDir
    New-Item -ItemType Directory -Force -Path $seedDir | Out-Null

    if ($Config.ProvisioningProfile -eq "Smoke") {
        $metaData = @"
instance-id: $($Config.VMName)-$(Get-Date -Format yyyyMMddHHmmss)
local-hostname: $($Config.HostName)
"@

        $userData = @"
#cloud-config
users:
  - default
  - name: $($Config.VMUser)
    gecos: workstation VM user
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: true
    ssh_authorized_keys:
      - $($Config.SshPublicKey)
ssh_pwauth: false
disable_root: true
package_update: false
package_upgrade: false
runcmd:
  - [ systemctl, enable, --now, ssh ]
  - [ bash, -lc, "printf 'PasswordAuthentication no\nPermitRootLogin no\nAllowUsers $($Config.VMUser)\n' >/etc/ssh/sshd_config.d/90-local-hardening.conf" ]
  - [ systemctl, restart, ssh ]
  - [ bash, -lc, "mkdir -p /home/$($Config.VMUser)/Work && chown -R $($Config.VMUser):$($Config.VMUser) /home/$($Config.VMUser)/Work" ]
final_message: "Ubuntu smoke workstation VM is ready after cloud-init. Uptime: `$UPTIME"
"@

        Set-Content -LiteralPath (Join-Path $seedDir "meta-data") -Value $metaData -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $seedDir "user-data") -Value $userData -Encoding ASCII
        $networkConfig = New-UbuntuNetworkConfig -Config $Config
        if (-not [string]::IsNullOrWhiteSpace($networkConfig)) {
            Set-Content -LiteralPath (Join-Path $seedDir "network-config") -Value $networkConfig -Encoding ASCII
        }
        New-IsoFromDirectory -SourceDir $seedDir -IsoPath $Config.Paths.SeedIsoPath -Label "cidata"
        return
    }

    $plainPasswordWsl = ([string]$Config.Password).Replace("'", "'\''")
    $passwordHash = (wsl.exe -d Ubuntu-24.04 -- bash -lc "openssl passwd -6 '$plainPasswordWsl'").Trim()
    if ([string]::IsNullOrWhiteSpace($passwordHash) -or -not $passwordHash.StartsWith('$6$')) {
        throw "Could not create password hash"
    }

    $workAppUrls = (([string[]]$Config.WorkAppUrls) -join " ").Trim()
    if ([string]::IsNullOrWhiteSpace($workAppUrls)) {
        $workAppUrls = "https://teams.microsoft.com/v2/ https://outlook.office.com/mail/"
    }

    $metaData = @"
instance-id: $($Config.VMName)-$(Get-Date -Format yyyyMMddHHmmss)
local-hostname: $($Config.HostName)
"@

    $userData = @"
#cloud-config
users:
  - default
  - name: $($Config.VMUser)
    gecos: workstation VM user
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    lock_passwd: false
    passwd: '$passwordHash'
    ssh_authorized_keys:
      - $($Config.SshPublicKey)
ssh_pwauth: false
disable_root: true
package_update: true
package_upgrade: false
packages:
  - openssh-server
  - wireguard
  - curl
  - ca-certificates
  - gnupg
  - git
  - tmux
  - vim
  - htop
  - net-tools
  - dnsutils
  - traceroute
  - tcpdump
  - jq
  - ripgrep
  - fzf
  - unzip
  - zip
  - tree
  - ncdu
  - xclip
  - xsel
  - libnotify-bin
  - fonts-noto-color-emoji
  - fonts-liberation
  - pavucontrol
  - mesa-utils
  - dbus-x11
  - x11-xserver-utils
  - linux-generic
  - xfce4
  - xfce4-goodies
  - xfce4-terminal
write_files:
  - path: /etc/sysctl.d/99-workstation-vm.conf
    permissions: "0644"
    owner: root:root
    content: |
      net.ipv4.ip_forward=0
  - path: /usr/local/bin/workstation-set-display-120hz
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      while true; do
        python3 - <<'PY'
      import re
      import subprocess

      target_width = $($Config.DisplayWidth)
      target_height = $($Config.DisplayHeight)
      target_refresh = $($Config.DisplayRefresh)
      query = subprocess.check_output(["xrandr", "--query"], text=True)
      output_match = re.search(r"^(\S+) connected", query, re.M)
      current_match = re.search(r"^\s*(\d+)x(\d+)\s+([0-9.]+)\*", query, re.M)
      if output_match and current_match:
          current_width = int(current_match.group(1))
          current_height = int(current_match.group(2))
          current_refresh = float(current_match.group(3))
          output = output_match.group(1)
          needs_target = current_width != target_width or current_height != target_height or current_refresh < (target_refresh - 10)
          width = target_width if needs_target else current_width
          height = target_height if needs_target else current_height
          name = f"{width}x{height}_{target_refresh}"
          cvt = subprocess.check_output(["cvt", str(width), str(height), str(target_refresh)], text=True)
          modeline = re.search(r'Modeline\s+"[^"]+"\s+(.+)', cvt)
          if modeline:
              rest = modeline.group(1).split()
              if name not in query:
                  subprocess.run(["xrandr", "--newmode", name, *rest], check=False)
              subprocess.run(["xrandr", "--addmode", output, name], check=False)
              subprocess.run(["xrandr", "--output", output, "--mode", name], check=False)
      PY
        if [ "x`$WORKSTATION_DISPLAY_ONCE" = "x1" ]; then
          exit 0
        fi
        sleep 5
      done
  - path: /usr/local/bin/workstation-session-setup
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      xset s off -dpms s noblank 2>/dev/null || true
      xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false 2>/dev/null || true
      xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -n -t int -s 0 2>/dev/null || true
      xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false 2>/dev/null || true
      xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -n -t bool -s false 2>/dev/null || true
  - path: /usr/local/bin/workstation-open-work-apps
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      exec microsoft-edge-stable --new-window $workAppUrls
runcmd:
  - [ systemctl, enable, --now, ssh ]
  - [ bash, -lc, "printf 'PasswordAuthentication no\nPermitRootLogin no\nAllowUsers $($Config.VMUser)\n' >/etc/ssh/sshd_config.d/90-local-hardening.conf" ]
  - [ systemctl, restart, ssh ]
  - [ bash, -lc, "echo xfce4-session > /home/$($Config.VMUser)/.xsession && chown $($Config.VMUser):$($Config.VMUser) /home/$($Config.VMUser)/.xsession" ]
  - [ bash, -lc, "groupadd -f nopasswdlogin && usermod -aG nopasswdlogin $($Config.VMUser)" ]
  - [ bash, -lc, "printf '[Desktop]\nSession=xfce\n' >/home/$($Config.VMUser)/.dmrc && chown $($Config.VMUser):$($Config.VMUser) /home/$($Config.VMUser)/.dmrc && chmod 0644 /home/$($Config.VMUser)/.dmrc" ]
  - [ bash, -lc, "mkdir -p /var/lib/AccountsService/users && printf '[org.freedesktop.DisplayManager.AccountsService]\nBackgroundFile='\\''/usr/share/backgrounds/xfce/xfce-shapes.svg'\\''\n\n[User]\nSession=xfce\nIcon=/home/$($Config.VMUser)/.face\nSystemAccount=false\n' >/var/lib/AccountsService/users/$($Config.VMUser)" ]
  - [ bash, -lc, "mkdir -p /home/$($Config.VMUser)/.config/autostart && printf '[Desktop Entry]\nType=Application\nName=Set Hyper-V Display 120Hz\nExec=/usr/local/bin/workstation-set-display-120hz\nX-GNOME-Autostart-enabled=true\n' >/home/$($Config.VMUser)/.config/autostart/workstation-set-display-120hz.desktop && printf '[Desktop Entry]\nType=Application\nName=Session Setup\nExec=/usr/local/bin/workstation-session-setup\nX-GNOME-Autostart-enabled=true\n' >/home/$($Config.VMUser)/.config/autostart/workstation-session-setup.desktop && chown -R $($Config.VMUser):$($Config.VMUser) /home/$($Config.VMUser)/.config" ]
  - [ bash, -lc, "mkdir -p /etc/lightdm/lightdm.conf.d && printf '[Seat:*]\nautologin-user=$($Config.VMUser)\nautologin-user-timeout=0\nuser-session=xfce\n' >/etc/lightdm/lightdm.conf.d/50-workstation-autologin.conf && systemctl restart lightdm || true" ]
  - [ bash, -lc, "install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor >/etc/apt/keyrings/packages.microsoft.gpg && chmod a+r /etc/apt/keyrings/packages.microsoft.gpg" ]
  - [ bash, -lc, "printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/edge stable main\n' >/etc/apt/sources.list.d/microsoft-edge.list" ]
  - [ bash, -lc, "printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main\n' >/etc/apt/sources.list.d/vscode.list" ]
  - [ bash, -lc, "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y microsoft-edge-stable code" ]
  - [ bash, -lc, "sudo -u $($Config.VMUser) env HOME=/home/$($Config.VMUser) code --install-extension ms-vscode-remote.remote-ssh --force --no-sandbox --user-data-dir /home/$($Config.VMUser)/.config/Code || true" ]
  - [ bash, -lc, "mkdir -p /home/$($Config.VMUser)/Work && chown -R $($Config.VMUser):$($Config.VMUser) /home/$($Config.VMUser)/Work" ]
  - [ bash, -lc, "mkdir -p /home/$($Config.VMUser)/Desktop && printf '[Desktop Entry]\nType=Application\nName=Work Apps\nExec=/usr/local/bin/workstation-open-work-apps\nIcon=microsoft-edge\nTerminal=false\n' >/home/$($Config.VMUser)/Desktop/Work-Apps.desktop && printf '[Desktop Entry]\nType=Application\nName=VS Code\nExec=code --no-sandbox\nIcon=code\nTerminal=false\n' >/home/$($Config.VMUser)/Desktop/VS-Code.desktop && printf '[Desktop Entry]\nType=Application\nName=Terminal\nExec=xfce4-terminal\nIcon=utilities-terminal\nTerminal=false\n' >/home/$($Config.VMUser)/Desktop/Terminal.desktop && chmod +x /home/$($Config.VMUser)/Desktop/*.desktop && chown -R $($Config.VMUser):$($Config.VMUser) /home/$($Config.VMUser)/Desktop" ]
final_message: "Ubuntu workstation VM is ready after cloud-init. Uptime: `$UPTIME"
"@

    Set-Content -LiteralPath (Join-Path $seedDir "meta-data") -Value $metaData -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $seedDir "user-data") -Value $userData -Encoding ASCII
    $networkConfig = New-UbuntuNetworkConfig -Config $Config
    if (-not [string]::IsNullOrWhiteSpace($networkConfig)) {
        Set-Content -LiteralPath (Join-Path $seedDir "network-config") -Value $networkConfig -Encoding ASCII
    }
    New-IsoFromDirectory -SourceDir $seedDir -IsoPath $Config.Paths.SeedIsoPath -Label "cidata"
}

function New-UbuntuWorkstation {
    param([hashtable]$Config)

    Ensure-UbuntuSshKey -Config $Config
    New-UbuntuVhd -Config $Config
    New-UbuntuSeedIso -Config $Config
    Set-WorkstationVmHardwareBaseline -Config $Config -VhdPath $Config.Paths.VhdPath -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
    Add-VMDvdDrive -VMName $Config.VMName -Path $Config.Paths.SeedIsoPath
    Start-VM -Name $Config.VMName
}

function Get-SafeIsoFileName {
    param([string]$Url)

    try {
        $uri = [Uri]$Url
        $name = [System.IO.Path]::GetFileName($uri.AbsolutePath)
    } catch {
        $name = ""
    }

    if ([string]::IsNullOrWhiteSpace($name) -or -not $name.EndsWith(".iso", [StringComparison]::OrdinalIgnoreCase)) {
        $name = "windows11-latest-x64.iso"
    }

    return ($name -replace '[^A-Za-z0-9._-]', '_')
}

function Get-WindowsIsoUrl {
    param([hashtable]$Config)

    Require-Command curl
    Require-Command powershell

    curl.exe -L --fail --output $Config.Paths.FidoPath ([string]$Config.FidoUrl)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download Fido.ps1 from $($Config.FidoUrl)"
    }

    $fidoArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $Config.Paths.FidoPath,
        "-Win", "11",
        "-Rel", ([string]$Config.WindowsRelease),
        "-Ed", ([string]$Config.WindowsEdition),
        "-Lang", ([string]$Config.WindowsLanguage),
        "-Arch", ([string]$Config.WindowsArch),
        "-GetUrl"
    )

    $output = & powershell.exe @fidoArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Fido failed to resolve the Windows 11 ISO URL:`n$($output -join "`n")"
    }

    $url = $output | Where-Object { $_ -match '^https://.+\.iso(\?|$)' } | Select-Object -First 1
    if (-not $url) {
        throw "Fido did not return a Windows ISO URL. Output:`n$($output -join "`n")"
    }

    return ([string]$url).Trim()
}

function Ensure-WindowsIso {
    param([hashtable]$Config)

    if (-not [string]::IsNullOrWhiteSpace($Config.WindowsIsoPath)) {
        $Config.WindowsIsoPath = Expand-ConfigPathValue ([string]$Config.WindowsIsoPath)
        if (-not (Test-Path $Config.WindowsIsoPath)) {
            throw "Windows ISO override not found: $($Config.WindowsIsoPath)"
        }
        return
    }

    $url = Get-WindowsIsoUrl -Config $Config
    $isoName = Get-SafeIsoFileName -Url $url
    $isoPath = Join-Path $Config.Paths.WindowsImageDir $isoName

    $needsDownload = $true
    if (Test-Path $isoPath) {
        $existing = Get-Item -LiteralPath $isoPath
        $needsDownload = $existing.Length -lt 3GB
    }

    if ($needsDownload) {
        if (Test-Path $isoPath) {
            Remove-Item -LiteralPath $isoPath -Force
        }
        curl.exe -L --fail --output $isoPath $url
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to download Windows 11 ISO from official Microsoft URL."
        }
    }

    $iso = Get-Item -LiteralPath $isoPath
    if ($iso.Length -lt 3GB) {
        throw "Downloaded Windows ISO is unexpectedly small: $($iso.FullName)"
    }

    $Config.WindowsIsoPath = $iso.FullName
}

function New-WindowsAnswerIso {
    param([hashtable]$Config)

    $seedDir = $Config.Paths.SeedDir
    New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
    $user = ConvertTo-XmlText ([string]$Config.VMUser)
    $password = ConvertTo-XmlText ([string]$Config.Password)
    $computerName = ConvertTo-XmlText ([string]$Config.VMName)
    $imageKey = "/IMAGE/NAME"
    $imageValue = ConvertTo-XmlText ([string]$Config.WindowsImageName)
    if ([string]::IsNullOrWhiteSpace($imageValue)) {
        if ([int]$Config.WindowsImageIndex -le 0) {
            throw "WindowsImageName or WindowsImageIndex must be set for Variant=Windows11."
        }
        $imageKey = "/IMAGE/INDEX"
        $imageValue = [string]([int]$Config.WindowsImageIndex)
    }

    $answer = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <SetupUILanguage>
        <UILanguage>en-US</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>EFI</Type>
              <Size>260</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>2</Order>
              <Type>MSR</Type>
              <Size>16</Size>
            </CreatePartition>
            <CreatePartition wcm:action="add">
              <Order>3</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Order>1</Order>
              <PartitionID>1</PartitionID>
              <Format>FAT32</Format>
              <Label>System</Label>
            </ModifyPartition>
            <ModifyPartition wcm:action="add">
              <Order>2</Order>
              <PartitionID>3</PartitionID>
              <Format>NTFS</Format>
              <Label>Windows</Label>
              <Letter>C</Letter>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>$imageKey</Key>
              <Value>$imageValue</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>3</PartitionID>
          </InstallTo>
        </OSImage>
      </ImageInstall>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Workstation VM</FullName>
        <Organization>Workstation</Organization>
      </UserData>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <ComputerName>$computerName</ComputerName>
      <TimeZone>Central European Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <AutoLogon>
        <Password>
          <Value>$password</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>999</LogonCount>
        <Username>$user</Username>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password>
              <Value>$password</Value>
              <PlainText>true</PlainText>
            </Password>
            <Description>workstation VM local user</Description>
            <DisplayName>$user</DisplayName>
            <Group>Administrators</Group>
            <Name>$user</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <RegisteredOwner>$user</RegisteredOwner>
    </component>
  </settings>
</unattend>
"@

    Set-Content -LiteralPath (Join-Path $seedDir "Autounattend.xml") -Value $answer -Encoding UTF8
    New-IsoFromDirectory -SourceDir $seedDir -IsoPath $Config.Paths.AnswerIsoPath -Label "AUTOUNATTEND"
}

function New-WindowsWorkstation {
    param([hashtable]$Config)

    Ensure-WindowsIso -Config $Config

    if (Test-Path $Config.Paths.VhdPath) {
        Remove-Item -LiteralPath $Config.Paths.VhdPath -Force
    }

    New-VHD -Path $Config.Paths.VhdPath -SizeBytes ([int64]$Config.VhdSizeBytes) -Dynamic | Out-Null
    New-WindowsAnswerIso -Config $Config
    Set-WorkstationVmHardwareBaseline -Config $Config -VhdPath $Config.Paths.VhdPath -SecureBootTemplate "MicrosoftWindows"

    Set-VMKeyProtector -VMName $Config.VMName -NewLocalKeyProtector
    Enable-VMTPM -VMName $Config.VMName

    $windowsDvd = Add-VMDvdDrive -VMName $Config.VMName -Path $Config.WindowsIsoPath -Passthru
    Add-VMDvdDrive -VMName $Config.VMName -Path $Config.Paths.AnswerIsoPath | Out-Null
    Set-VMFirmware -VMName $Config.VMName -FirstBootDevice $windowsDvd

    Start-VM -Name $Config.VMName

    if (-not $SkipGuestProvisioning) {
        if ($Config.ProvisioningProfile -eq "Smoke") {
            return
        }
        Invoke-WindowsGuestProvisioning -Config $Config
    }
}

function Wait-UbuntuGuestProvisioning {
    param(
        [hashtable]$Config,
        [int]$TimeoutMinutes = 75
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $target = "{0}@{1}" -f $Config.VMUser, $Config.MaintenanceSshHost
    $sshOptions = @(
        "-i", $Config.Paths.SshKeyPath,
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new"
    )

    while ((Get-Date) -lt $deadline) {
        & ssh.exe @sshOptions $target "true" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $remainingSeconds = [math]::Max(60, [int]($deadline - (Get-Date)).TotalSeconds)
            & ssh.exe @sshOptions $target "timeout $remainingSeconds cloud-init status --wait >/dev/null && cloud-init status | grep -q 'status: done'" 2>$null
            if ($LASTEXITCODE -eq 0) {
                return
            }
        }
        Start-Sleep -Seconds 10
    }

    throw "Ubuntu guest did not finish provisioning within $TimeoutMinutes minutes."
}

function New-CleanCheckpoint {
    param([hashtable]$Config)

    if ($SkipCleanCheckpoint -or -not [bool]$Config.CreateCleanCheckpoint) {
        return
    }

    $snapshotName = [string]$Config.CleanCheckpointName
    if ([string]::IsNullOrWhiteSpace($snapshotName)) {
        $snapshotName = "clean-ready-no-creds-no-vpn"
    }

    $existing = Get-VMSnapshot -VMName $Config.VMName -Name $snapshotName -ErrorAction SilentlyContinue
    if ($existing) {
        return
    }

    Checkpoint-VM -Name $Config.VMName -SnapshotName $snapshotName | Out-Null
}

function Wait-WindowsPowerShellDirect {
    param(
        [string]$VMName,
        [pscredential]$Credential,
        [int]$TimeoutMinutes = 60
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            $result = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock { "ready" } -ErrorAction Stop
            if ($result -contains "ready") {
                return
            }
        } catch {
            Start-Sleep -Seconds 20
        }
    }
    throw "Windows guest did not become reachable through PowerShell Direct within $TimeoutMinutes minutes."
}

function Invoke-WindowsGuestProvisioning {
    param([hashtable]$Config)

    $securePassword = ConvertTo-SecureString ([string]$Config.Password) -AsPlainText -Force
    $credential = [pscredential]::new(([string]$Config.VMUser), $securePassword)
    $workAppUrls = (([string[]]$Config.WorkAppUrls) -join " ").Trim()
    if ([string]::IsNullOrWhiteSpace($workAppUrls)) {
        $workAppUrls = "https://teams.microsoft.com/v2/ https://outlook.office.com/mail/"
    }

    Wait-WindowsPowerShellDirect -VMName $Config.VMName -Credential $credential

    $provision = @'
$ErrorActionPreference = "Continue"

New-Item -ItemType Directory -Force -Path C:\WorkstationVm | Out-Null

powercfg /setactive SCHEME_MIN 2>$null
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0

Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Type DWord -Value 1
Disable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue | Out-Null
Set-Service -Name TermService -StartupType Manual -ErrorAction SilentlyContinue

$fpsHtml = @"
<!doctype html>
<html>
<head><meta charset="utf-8"><title>FPS Check</title></head>
<body style="font-family:Segoe UI,Arial;margin:32px;background:#101418;color:#e6edf3">
<h1>FPS Check</h1>
<div id="out" style="font-size:32px"></div>
<script>
let last = performance.now();
let frames = 0;
let started = last;
function tick(now) {
  frames++;
  if (now - started >= 5000) {
    document.getElementById("out").textContent = "FPS: " + (frames * 1000 / (now - started)).toFixed(2);
    frames = 0;
    started = now;
  }
  requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
</script>
</body>
</html>
"@
Set-Content -Path C:\WorkstationVm\fps-check.html -Value $fpsHtml -Encoding UTF8

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($winget) {
    winget source update | Out-Null
    $packages = @(
        "Microsoft.VisualStudioCode",
        "Git.Git",
        "WireGuard.WireGuard",
        "7zip.7zip",
        "BurntSushi.ripgrep.GNU",
        "jqlang.jq"
    )
    foreach ($id in $packages) {
        winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
    }
}

$codeCandidates = @(
    "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
    "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
)
$code = $codeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($code) {
    & $code --install-extension ms-vscode-remote.remote-ssh --force | Out-Null
}

$desktop = [Environment]::GetFolderPath("Desktop")
$shell = New-Object -ComObject WScript.Shell

$edge = "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $edge)) { $edge = "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe" }
if (Test-Path $edge) {
    $shortcut = $shell.CreateShortcut((Join-Path $desktop "Work Apps.lnk"))
    $shortcut.TargetPath = $edge
    $shortcut.Arguments = "--new-window __WORK_APP_URLS__"
    $shortcut.Save()

    $fps = $shell.CreateShortcut((Join-Path $desktop "FPS Check.lnk"))
    $fps.TargetPath = $edge
    $fps.Arguments = "file:///C:/WorkstationVm/fps-check.html"
    $fps.Save()
}

if ($code) {
    $shortcut = $shell.CreateShortcut((Join-Path $desktop "VS Code.lnk"))
    $shortcut.TargetPath = $code
    $shortcut.Save()
}

$terminal = $shell.CreateShortcut((Join-Path $desktop "PowerShell.lnk"))
$terminal.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$terminal.Save()

New-Item -ItemType Directory -Force -Path C:\Work | Out-Null
"provisioned=$(Get-Date -Format o)" | Set-Content -Path C:\WorkstationVm\provisioned.txt -Encoding ASCII
'@

    $provision = $provision.Replace("__WORK_APP_URLS__", $workAppUrls)
    Invoke-Command -VMName $Config.VMName -Credential $credential -ScriptBlock ([scriptblock]::Create($provision))
}

$config = Import-WorkstationConfig -Root $ConfigRoot -Variant $Variant -LocalPath $LocalConfigPath
Set-Override -Config $config -Key "VMName" -Value $VMName -WasProvided $PSBoundParameters.ContainsKey("VMName")
Set-Override -Config $config -Key "BaseDir" -Value $BaseDir -WasProvided $PSBoundParameters.ContainsKey("BaseDir")
Set-Override -Config $config -Key "VMUser" -Value $VMUser -WasProvided $PSBoundParameters.ContainsKey("VMUser")
Set-Override -Config $config -Key "Password" -Value $PlainPassword -WasProvided $PSBoundParameters.ContainsKey("PlainPassword")
Set-Override -Config $config -Key "SwitchName" -Value $SwitchName -WasProvided $PSBoundParameters.ContainsKey("SwitchName")
Set-Override -Config $config -Key "ImageCacheRoot" -Value $ImageCacheRoot -WasProvided $PSBoundParameters.ContainsKey("ImageCacheRoot")
Set-Override -Config $config -Key "ProvisioningProfile" -Value $ProvisioningProfile -WasProvided ($PSBoundParameters.ContainsKey("ProvisioningProfile") -and -not [string]::IsNullOrWhiteSpace($ProvisioningProfile))
Set-Override -Config $config -Key "WindowsIsoPath" -Value $WindowsIsoPath -WasProvided $PSBoundParameters.ContainsKey("WindowsIsoPath")
Set-Override -Config $config -Key "WindowsRelease" -Value $WindowsRelease -WasProvided $PSBoundParameters.ContainsKey("WindowsRelease")
Set-Override -Config $config -Key "WindowsEdition" -Value $WindowsEdition -WasProvided $PSBoundParameters.ContainsKey("WindowsEdition")
Set-Override -Config $config -Key "WindowsLanguage" -Value $WindowsLanguage -WasProvided $PSBoundParameters.ContainsKey("WindowsLanguage")
Set-Override -Config $config -Key "WindowsArch" -Value $WindowsArch -WasProvided $PSBoundParameters.ContainsKey("WindowsArch")
Set-Override -Config $config -Key "WindowsImageName" -Value $WindowsImageName -WasProvided $PSBoundParameters.ContainsKey("WindowsImageName")
Set-Override -Config $config -Key "FidoUrl" -Value $FidoUrl -WasProvided $PSBoundParameters.ContainsKey("FidoUrl")
Set-Override -Config $config -Key "WindowsImageIndex" -Value $WindowsImageIndex -WasProvided $PSBoundParameters.ContainsKey("WindowsImageIndex")
if ($PSBoundParameters.ContainsKey("MemoryStartupBytes")) { $config.MemoryStartupGB = [math]::Ceiling($MemoryStartupBytes / 1GB) }
if ($PSBoundParameters.ContainsKey("VhdSizeBytes")) { $config.VhdSizeGB = [math]::Ceiling($VhdSizeBytes / 1GB) }
Set-Override -Config $config -Key "CpuCount" -Value $CpuCount -WasProvided $PSBoundParameters.ContainsKey("CpuCount")
Set-Override -Config $config -Key "DisplayWidth" -Value $DisplayWidth -WasProvided $PSBoundParameters.ContainsKey("DisplayWidth")
Set-Override -Config $config -Key "DisplayHeight" -Value $DisplayHeight -WasProvided $PSBoundParameters.ContainsKey("DisplayHeight")
Set-Override -Config $config -Key "DisplayRefresh" -Value $DisplayRefresh -WasProvided $PSBoundParameters.ContainsKey("DisplayRefresh")

$config.Variant = ([string]$config.Variant).Trim()
if ($config.Variant -notin @("Ubuntu", "Windows11")) {
    throw "Variant must be Ubuntu or Windows11. Current value: $($config.Variant)"
}

$config.BaseDir = Expand-ConfigPathValue ([string]$config.BaseDir)
if ([string]::IsNullOrWhiteSpace([string]$config.ProvisioningProfile)) {
    $config.ProvisioningProfile = "Full"
}
if ($config.ProvisioningProfile -notin @("Full", "Smoke")) {
    throw "ProvisioningProfile must be Full or Smoke. Current value: $($config.ProvisioningProfile)"
}
$config.MemoryStartupBytes = [int64]$config.MemoryStartupGB * 1GB
$config.VhdSizeBytes = [int64]$config.VhdSizeGB * 1GB
if ([string]::IsNullOrWhiteSpace($config.Password)) {
    $config.Password = New-RandomPassword
}

$paths = New-WorkstationPaths -Config $config
$config.Paths = $paths

Assert-CommonPreconditions -Config $config
New-Item -ItemType Directory -Force -Path $paths.LinuxImageDir, $paths.WindowsImageDir, $paths.SeedDir, $paths.VmDir | Out-Null
Write-PasswordFile -Path $paths.PasswordPath -Variant $config.Variant -User $config.VMUser -Password $config.Password

switch ($config.Variant) {
    "Ubuntu" {
        New-UbuntuWorkstation -Config $config
        if (-not $SkipCleanCheckpoint -and [bool]$config.CreateCleanCheckpoint) {
            Wait-UbuntuGuestProvisioning -Config $config
        }
    }
    "Windows11" {
        New-WindowsWorkstation -Config $config
    }
}

$windowsGuestProvisioningSkipped = $config.Variant -eq "Windows11" -and ($SkipGuestProvisioning -or $config.ProvisioningProfile -eq "Smoke")
if (-not $windowsGuestProvisioningSkipped) {
    New-CleanCheckpoint -Config $config
}

[pscustomobject]@{
    Variant = $config.Variant
    VMName = $config.VMName
    BaseDir = $paths.BaseDir
    User = $config.VMUser
    SwitchName = $config.SwitchName
    MemoryGB = [math]::Round($config.MemoryStartupBytes / 1GB, 2)
    CpuCount = $config.CpuCount
    PasswordFile = $paths.PasswordPath
    Vhd = $paths.VhdPath
    SeedIso = if ($config.Variant -eq "Ubuntu") { $paths.SeedIsoPath } else { $paths.AnswerIsoPath }
    WindowsIso = if ($config.Variant -eq "Windows11") { $config.WindowsIsoPath } else { "" }
}
