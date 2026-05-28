$ErrorActionPreference = "Stop"; $scriptArgs = $args
. (Join-Path $PSScriptRoot "lib\iso-writer.ps1")

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

function Log($message) {
    Write-Host "[$(Get-Date -Format HH:mm:ss)] $message"
}

function Password {
    -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
}

function WingetPackage($package) {
    if ($package -is [string]) {
        if ([string]::IsNullOrWhiteSpace($package)) { return $null }
        return [pscustomobject]@{
            id = [string]$package
            source = "winget"
            exact = $true
            silent = $true
        }
    }

    $id = [string]$package.id
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }

    [ordered]@{
        id = $id
        source = if ([string]::IsNullOrWhiteSpace([string]$package.source)) { "winget" } else { [string]$package.source }
        name = if ([string]::IsNullOrWhiteSpace([string]$package.name)) { $id } else { [string]$package.name }
        exact = if ($null -eq $package.PSObject.Properties["exact"]) { $true } else { [bool]$package.exact }
        silent = if ($null -eq $package.PSObject.Properties["silent"]) { $true } else { [bool]$package.silent }
        override = if ($null -eq $package.PSObject.Properties["override"]) { "" } else { [string]$package.override }
        url = if ($null -eq $package.PSObject.Properties["url"]) { "" } else { [string]$package.url }
        silentArgs = if ($null -eq $package.PSObject.Properties["silentArgs"]) { "" } else { [string]$package.silentArgs }
        checkPath = if ($null -eq $package.PSObject.Properties["checkPath"]) { "" } else { [string]$package.checkPath }
    }
}

function GpuConfig($cfg) {
    if ($null -eq $cfg.gpu -and $null -ne $cfg.gpuPv) {
        $cfg | Add-Member -Force NoteProperty "gpu" $cfg.gpuPv
    }
    $gpu = ChildConfig $cfg "gpu"
    Default $gpu "enabled" $false
    Default $gpu "gpuName" "AUTO"
    Default $gpu "allocationPercent" 25
    return $gpu
}

function RemoteStreamingConfig($cfg) {
    $streaming = ChildConfig $cfg "remoteStreaming"
    Default $streaming "enabled" $false
    Default $streaming "installSunshine" $true
    Default $streaming "installVirtualDisplayDriver" $true
    Default $streaming "sunshineUser" ""
    Default $streaming "sunshinePassword" ""
    Default $streaming "sunshineName" ""
    Default $streaming "port" 47989
    Default $streaming "displayWidth" ""
    Default $streaming "displayHeight" ""
    Default $streaming "refreshRate" 120
    Default $streaming "virtualDisplayCount" 1
    Default $streaming "openFirewall" $true

    if ([string]::IsNullOrWhiteSpace([string]$streaming.sunshineUser)) { $streaming.sunshineUser = $cfg.user }
    if ([string]::IsNullOrWhiteSpace([string]$streaming.sunshineName)) { $streaming.sunshineName = $cfg.vmName }
    if ([bool]$streaming.enabled -and [bool]$streaming.installSunshine -and [string]::IsNullOrWhiteSpace([string]$streaming.sunshinePassword)) {
        $streaming.sunshinePassword = Password
    }

    return $streaming
}

function ResolveStreamingDisplay($streaming, $displayWidth, $displayHeight) {
    if (-not [bool]$streaming.enabled -or -not [bool]$streaming.installVirtualDisplayDriver) { return }

    if ((Number $streaming.displayWidth) -le 0) { $streaming.displayWidth = [int]$displayWidth }
    if ((Number $streaming.displayHeight) -le 0) { $streaming.displayHeight = [int]$displayHeight }
}

function WingetPackages($cfg, $streaming) {
    $packages = @($cfg.wingetPackages)
    if ([bool]$streaming.enabled) {
        if ([bool]$streaming.installVirtualDisplayDriver) { $packages += "Microsoft.VCRedist.2015+.x64" }
        if ([bool]$streaming.installSunshine) { $packages += "LizardByte.Sunshine" }
    }

    $seen = @{}
    foreach ($package in $packages) {
        $entry = WingetPackage $package
        if (-not $entry) { continue }

        $key = "$($entry.source)|$($entry.id)".ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $entry
    }
}

function BitLockerPassword {
    $sets = @("abcdefghijkmnopqrstuvwxyz", "ABCDEFGHJKLMNPQRSTUVWXYZ", "23456789", "!@#$%_-+=")
    $all = ($sets -join "").ToCharArray()
    $chars = @($sets | ForEach-Object { $_[(Get-Random -Maximum $_.Length)] })
    $chars += 1..28 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

function Xml($text) {
    [Security.SecurityElement]::Escape([string]$text)
}

function Number($value) {
    if ([string]::IsNullOrWhiteSpace([string]$value)) { return 0 }
    return [int]$value
}

function RemoveVm($name) {
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if ($vm) {
        Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $name -Force
    }
}

function SecureText($text) {
    $secure = [Security.SecureString]::new()
    foreach ($ch in ([string]$text).ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return $secure
}

function GuestCredential($cfg) {
    $password = SecureText $cfg.password
    [pscredential]::new($cfg.user, $password)
}

function SecurePrivateKey($path) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $path /inheritance:r /grant:r "${user}:F" | Out-Null
}

function CmdQuote($text) {
    '"' + ([string]$text).Replace('"', '') + '"'
}

function EnsureSshKey($cfg, $baseDir) {
    if (-not [bool]$cfg.sshEnabled) { return $null }

    $privateKey = Join-Path $baseDir "ssh_key_ed25519.key"
    $publicKey = "$privateKey.pub"
    if (-not (Test-Path -LiteralPath $privateKey)) {
        $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
        if (-not $sshKeygen) { throw "ssh-keygen.exe was not found. Run .\prepare-host.ps1 as Administrator first." }
        $command = "$(CmdQuote $sshKeygen.Source) -t ed25519 -N """" -f $(CmdQuote $privateKey) -C $(CmdQuote "$($cfg.vmName)-workstation")"
        & cmd.exe /d /c $command | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $privateKey)) { throw "SSH key generation failed." }
    }
    if (-not (Test-Path -LiteralPath $publicKey)) {
        & (Get-Command ssh-keygen.exe).Source -y -f $privateKey | Set-Content -LiteralPath $publicKey -Encoding ascii
    }
    SecurePrivateKey $privateKey

    [pscustomobject]@{
        Private = $privateKey
        Public = $publicKey
    }
}

function WindowsIso($cfg, $cacheDir) {
    if (-not [string]::IsNullOrWhiteSpace($cfg.windowsIsoPath)) { return FullPath $cfg.windowsIsoPath }

    $iso = Join-Path $cacheDir "windows11.iso"
    if (Test-Path $iso) {
        Log "Using cached Windows ISO: $iso"
        return $iso
    }

    $fido = Join-Path $PSScriptRoot "vendor\Fido.ps1"
    if (-not (Test-Path $fido)) { throw "Missing vendor\Fido.ps1." }

    $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $fido,
        "-Win", "11",
        "-Rel", $cfg.windowsRelease,
        "-Ed", $cfg.windowsEdition,
        "-Lang", $cfg.windowsLanguage,
        "-Arch", $cfg.windowsArch,
        "-GetUrl"
    )
    $url = & powershell.exe @args | Where-Object { $_ -match '^https://.+\.iso(\?|$)' } | Select-Object -First 1
    if (-not $url) { throw "Could not resolve Windows ISO URL." }

    Log "Downloading Windows ISO to $iso"
    Invoke-WebRequest -Uri $url -OutFile $iso
    return $iso
}

function InstallMedia($cfg, $baseDir, $windowsIso, $sshKey, $streaming) {
    $dir = Join-Path $baseDir "answer"
    $installIso = Join-Path $baseDir "$($cfg.vmName)-install.iso"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $packages = @(WingetPackages $cfg $streaming)
    Set-Content -LiteralPath (Join-Path $dir "packages.txt") -Value @($packages | ForEach-Object { "$($_.source):$($_.id)" }) -Encoding UTF8
    if ($packages.Count -eq 0) {
        "[]" | Set-Content -LiteralPath (Join-Path $dir "packages.json") -Encoding UTF8
    } else {
        $packages | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir "packages.json") -Encoding UTF8
    }
    [ordered]@{
        autoLogonUser = $cfg.user
        autoLogonPassword = $cfg.password
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir "bootstrap-config.json") -Encoding UTF8
    if ([bool]$streaming.enabled) {
        [ordered]@{
            enabled = [bool]$streaming.enabled
            installSunshine = [bool]$streaming.installSunshine
            installVirtualDisplayDriver = [bool]$streaming.installVirtualDisplayDriver
            sunshineUser = [string]$streaming.sunshineUser
            sunshinePassword = [string]$streaming.sunshinePassword
            sunshineName = [string]$streaming.sunshineName
            port = [int]$streaming.port
            displayWidth = [int]$streaming.displayWidth
            displayHeight = [int]$streaming.displayHeight
            refreshRate = [int]$streaming.refreshRate
            virtualDisplayCount = [int]$streaming.virtualDisplayCount
            openFirewall = [bool]$streaming.openFirewall
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $dir "streaming.json") -Encoding UTF8
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "bootstrap-windows.ps1") -Destination $dir -Force
    if ($sshKey) {
        Copy-Item -LiteralPath $sshKey.Public -Destination (Join-Path $dir "ssh_authorized_key.pub") -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($cfg.guestIpAddress)) {
        [ordered]@{
            ipAddress = $cfg.guestIpAddress
            prefixLength = if ($cfg.guestPrefixLength) { [int]$cfg.guestPrefixLength } else { 24 }
            gateway = $cfg.guestGateway
            dnsServers = @($cfg.guestDnsServers)
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $dir "network.json") -Encoding UTF8
    }

    $xml = Get-Content -Raw (Join-Path $PSScriptRoot "templates\windows11-autounattend.xml")
    $xml = $xml.Replace("{{VM_NAME}}", (Xml $cfg.vmName))
    $xml = $xml.Replace("{{USER}}", (Xml $cfg.user))
    $xml = $xml.Replace("{{PASSWORD}}", (Xml $cfg.password))
    $xml = $xml.Replace("{{WINDOWS_IMAGE_NAME}}", (Xml $cfg.windowsImageName))
    Set-Content -LiteralPath (Join-Path $dir "Autounattend.xml") -Value $xml -Encoding UTF8

    $mounted = Mount-DiskImage -ImagePath $windowsIso -PassThru
    try {
        $volume = $mounted | Get-Volume
        $source = "$($volume.DriveLetter):\"
        $bootImage = Join-Path $source "efi\microsoft\boot\efisys_noprompt.bin"
        if (-not (Test-Path $bootImage)) { $bootImage = Join-Path $source "efi\microsoft\boot\efisys.bin" }
        New-InstallIso -SourceDir $source -OverlayDir $dir -IsoPath $installIso -BootImagePath $bootImage -VolumeName "WORKSTATION" | Out-Null
    } finally {
        Dismount-DiskImage -ImagePath $windowsIso | Out-Null
    }

    [pscustomobject]@{
        InstallIso = $installIso
    }
}

function ProbeGuestReady($cfg) {
    $probe = {
        param($vmName, $user, $password)

        $secure = [Security.SecureString]::new()
        foreach ($ch in ([string]$password).ToCharArray()) { $secure.AppendChar($ch) }
        $secure.MakeReadOnly()
        $credential = [pscredential]::new($user, $secure)

        Invoke-Command -VMName $vmName -Credential $credential -ScriptBlock {
            $rdp = (Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server").fDenyTSConnections -eq 0
            $rdpPort = [bool](Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue)
            [pscustomobject]@{
                ComputerName = $env:COMPUTERNAME
                BootstrapDone = Test-Path "C:\WorkstationVM\bootstrap.done"
                RdpEnabled = $rdp
                RdpListening = $rdpPort
            }
        } -ErrorAction Stop
    }

    $job = Start-Job -ScriptBlock $probe -ArgumentList $cfg.vmName, $cfg.user, $cfg.password
    try {
        $done = Wait-Job -Job $job -Timeout 20
        if (-not $done) { return $null }
        return Receive-Job -Job $job -ErrorAction Stop
    } catch {
        return $null
    } finally {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function WaitForReady($cfg) {
    $start = Get-Date
    $timeoutMinutes = Number $cfg.bootstrapTimeoutMinutes
    if ($timeoutMinutes -le 0) { $timeoutMinutes = 180 }
    $deadline = (Get-Date).AddMinutes($timeoutMinutes)
    $attempt = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++
        $elapsed = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
        $percent = [math]::Min(99, [int](((Get-Date) - $start).TotalSeconds / ($timeoutMinutes * 60) * 100))
        Write-Progress -Activity "Waiting for VM bootstrap" -Status "$elapsed minutes elapsed" -PercentComplete $percent
        if (($attempt -eq 1) -or ($attempt % 2 -eq 0)) {
            Log "Waiting for guest bootstrap to finish ($elapsed min elapsed)"
        }

        $state = ProbeGuestReady $cfg
        if ($state -and $state.BootstrapDone -and $state.RdpEnabled -and $state.RdpListening) {
            Write-Progress -Activity "Waiting for VM bootstrap" -Completed
            Log "Guest bootstrap is complete and RDP is listening"
            return $state
        }

        Start-Sleep -Seconds 30
    }

    throw "VM did not become ready within $timeoutMinutes minutes."
}

function InitializeDataDisk($cfg, $dataVhd, $bitLockerPassword) {
    if ((Number $cfg.dataDiskGB) -le 0) { return }

    New-VHD -Path $dataVhd -SizeBytes ([int64]$cfg.dataDiskGB * 1GB) -Dynamic | Out-Null
    Add-VMHardDiskDrive -VMName $cfg.vmName -Path $dataVhd | Out-Null

    Invoke-Command -VMName $cfg.vmName -Credential (GuestCredential $cfg) -ArgumentList $cfg.dataDiskLetter, $cfg.dataDiskLabel, ([bool]$cfg.dataDiskBitLocker), $bitLockerPassword -ScriptBlock {
        param($letter, $label, $useBitLocker, $bitLockerPassword)

        $letter = ([string]$letter).TrimEnd(":")
        $mountPoint = "${letter}:"
        for ($i = 0; $i -lt 30; $i++) {
            Update-HostStorageCache -ErrorAction SilentlyContinue
            $disk = Get-Disk | Where-Object PartitionStyle -eq "RAW" | Sort-Object Number | Select-Object -First 1
            if ($disk) { break }
            Start-Sleep -Seconds 2
        }
        if (-not $disk) { throw "Data disk did not appear in the guest." }

        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        $partition = New-Partition -DiskNumber $disk.Number -DriveLetter $letter -UseMaximumSize
        Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false | Out-Null

        if ($useBitLocker) {
            $secure = [Security.SecureString]::new()
            foreach ($ch in ([string]$bitLockerPassword).ToCharArray()) { $secure.AppendChar($ch) }
            $secure.MakeReadOnly()
            Enable-BitLocker -MountPoint $mountPoint -PasswordProtector -Password $secure -UsedSpaceOnly -SkipHardwareTest
            Resume-BitLocker -MountPoint $mountPoint
            $lastStatus = ""
            for ($i = 0; $i -lt 180; $i++) {
                $volume = Get-BitLockerVolume -MountPoint $mountPoint
                if ($volume.VolumeStatus -eq "EncryptionPaused") {
                    Resume-BitLocker -MountPoint $mountPoint
                }
                $status = "BitLocker $mountPoint protection=$($volume.ProtectionStatus) status=$($volume.VolumeStatus) lock=$($volume.LockStatus) encrypted=$($volume.EncryptionPercentage)%"
                if ($status -ne $lastStatus) {
                    Write-Output $status
                    $lastStatus = $status
                }
                if ($volume.ProtectionStatus -eq "On" -and $volume.VolumeStatus -ne "EncryptionInProgress") { break }
                Start-Sleep -Seconds 5
            }
            $volume = Get-BitLockerVolume -MountPoint $mountPoint
            if ($volume.ProtectionStatus -ne "On") {
                throw "BitLocker did not enable on $mountPoint. Protection=$($volume.ProtectionStatus) Status=$($volume.VolumeStatus) Lock=$($volume.LockStatus) Encrypted=$($volume.EncryptionPercentage)%"
            }
        }

        Get-Volume -DriveLetter $letter | Select-Object DriveLetter, FileSystemLabel, Size
    } | Out-Host
}

function VmIPv4Addresses($vmName) {
    @(Get-VMNetworkAdapter -VMName $vmName |
        Select-Object -ExpandProperty IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -ne '0.0.0.0' })
}

function WriteConnectionInfo($cfg, $streaming, $baseDir) {
    if (-not [bool]$streaming.enabled) { return }

    $ip = VmIPv4Addresses $cfg.vmName | Select-Object -First 1
    if (-not $ip) { return }

    $webPort = [int]$streaming.port + 1
    Add-Content -LiteralPath (Join-Path $baseDir "credentials.txt") -Value @(
        "MoonlightHost: $ip",
        "SunshineWebUi: https://${ip}:$webPort"
    )
}

function WriteRdpFile($configPath) {
    $script = Join-Path $PSScriptRoot "write-rdp-file.ps1"
    if (-not (Test-Path -LiteralPath $script)) { return }

    try {
        & $script --config $configPath
    } catch {
        Write-Warning "RDP file was not written: $_"
    }
}

function WriteGpuPvConfig($cfg, $gpu, $baseDir) {
    $path = Join-Path $baseDir "gpu-pv.json"
    [ordered]@{
        vmName = [string]$cfg.vmName
        credentialsPath = (Join-Path $baseDir "credentials.txt")
        gpuName = [string]$gpu.gpuName
        allocationPercent = [int]$gpu.allocationPercent
    } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function RunRemoteStreamingSetup($cfg, $streaming) {
    if (-not [bool]$streaming.enabled) { return }

    Invoke-Command -VMName $cfg.vmName -Credential (GuestCredential $cfg) -ScriptBlock {
        $root = "C:\WorkstationVM"
        New-Item -ItemType Directory -Force -Path $root | Out-Null

        $media = Get-PSDrive -PSProvider FileSystem |
            Where-Object {
                (Test-Path (Join-Path $_.Root "bootstrap-windows.ps1")) -and
                (Test-Path (Join-Path $_.Root "streaming.json"))
            } |
            Select-Object -First 1
        if (-not $media) { throw "Install media with streaming setup files was not found." }

        $bootstrap = Join-Path $root "bootstrap-windows.ps1"
        $streamingConfig = Join-Path $root "streaming.json"
        Copy-Item -LiteralPath (Join-Path $media.Root "bootstrap-windows.ps1") -Destination $bootstrap -Force
        Copy-Item -LiteralPath (Join-Path $media.Root "streaming.json") -Destination $streamingConfig -Force

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $bootstrap --streaming-config $streamingConfig
        if ($LASTEXITCODE -ne 0) { throw "Remote streaming setup failed with exit code $LASTEXITCODE." }
    } | Out-Host
}

function ApplyGpuPv($cfg, $gpu, $baseDir) {
    if (-not [bool]$gpu.enabled) { return $null }

    $script = Join-Path $PSScriptRoot "enable-gpu-pv.ps1"
    if (-not (Test-Path -LiteralPath $script)) { throw "Missing enable-gpu-pv.ps1." }

    $gpuConfig = WriteGpuPvConfig $cfg $gpu $baseDir
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script --config $gpuConfig
    if ($LASTEXITCODE -ne 0) { throw "GPU-PV setup failed." }

    return (WaitForReady $cfg)
}

function HostDisplay {
    $mode = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.CurrentHorizontalResolution -and $_.CurrentVerticalResolution } |
        Sort-Object { [int64]$_.CurrentHorizontalResolution * [int64]$_.CurrentVerticalResolution } -Descending |
        Select-Object -First 1
    if ($mode) {
        return [pscustomobject]@{ Width = [int]$mode.CurrentHorizontalResolution; Height = [int]$mode.CurrentVerticalResolution }
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        return [pscustomobject]@{ Width = $bounds.Width; Height = $bounds.Height }
    } catch {
        return [pscustomobject]@{ Width = 0; Height = 0 }
    }
}

$configPath = ArgValue "config"
if ([string]::IsNullOrWhiteSpace($configPath)) {
    throw "Usage: .\create-workstation-vm.ps1 --config config\windows.json"
}

$cfg = Get-Content -Raw (FullPath $configPath) | ConvertFrom-Json
@{
    vmName = "WorkstationW11"
    user = "work"
    password = ""
    switchName = "Default Switch"
    baseDir = "~/VMs/WorkstationW11"
    imageCacheDir = "~/VMs/_image-cache/windows"
    memoryGB = 8
    cpuCount = 4
    diskGB = 128
    dataDiskGB = 64
    dataDiskLetter = "W"
    dataDiskLabel = "WorkData"
    dataDiskBitLocker = $true
    sshEnabled = $true
    displayWidth = ""
    displayHeight = ""
    bootstrapTimeoutMinutes = 180
    recreate = $false
    wingetPackages = @("Microsoft.VisualStudioCode", "Git.Git", "WireGuard.WireGuard", "TorProject.TorBrowser")
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }

if ([string]::IsNullOrWhiteSpace($cfg.password)) { $cfg.password = Password }
Log "Preparing workstation VM '$($cfg.vmName)'"

$gpu = GpuConfig $cfg
$streaming = RemoteStreamingConfig $cfg

$displayWidth = Number $cfg.displayWidth
$displayHeight = Number $cfg.displayHeight
if (($displayWidth -le 0) -or ($displayHeight -le 0)) {
    $display = HostDisplay
    if ($displayWidth -le 0) { $displayWidth = $display.Width }
    if ($displayHeight -le 0) { $displayHeight = $display.Height }
}
ResolveStreamingDisplay $streaming $displayWidth $displayHeight

$baseDir = FullPath $cfg.baseDir
$cacheDir = FullPath $cfg.imageCacheDir
$vmDir = Join-Path $baseDir "vm"
$vhd = Join-Path $vmDir "$($cfg.vmName).vhdx"
$dataVhd = Join-Path $vmDir "$($cfg.vmName)-data.vhdx"
$gpuPvState = Join-Path $vmDir "gpu-pv-state.json"

New-Item -ItemType Directory -Force -Path $baseDir, $cacheDir, $vmDir | Out-Null
Log "Using base directory: $baseDir"

$existingVm = Get-VM -Name $cfg.vmName -ErrorAction SilentlyContinue
$existingDisk = Test-Path $vhd
$existingDataDisk = Test-Path $dataVhd
if ([bool]$cfg.recreate) {
    Log "Recreate requested. Removing existing VM and disks if present"
    RemoveVm $cfg.vmName
    if ($existingDisk) { Remove-Item -LiteralPath $vhd -Force }
    if ($existingDataDisk) { Remove-Item -LiteralPath $dataVhd -Force }
    if (Test-Path -LiteralPath $gpuPvState) { Remove-Item -LiteralPath $gpuPvState -Force }
} elseif ($existingVm -or $existingDisk -or $existingDataDisk) {
    throw "VM or disk already exists. Set recreate to true only when you intentionally want to replace it."
}

$bitLockerPassword = ""
if ((Number $cfg.dataDiskGB) -gt 0 -and [bool]$cfg.dataDiskBitLocker) { $bitLockerPassword = BitLockerPassword }
Log "Preparing SSH key and credentials"
$sshKey = EnsureSshKey $cfg $baseDir

$credentialText = @("User: $($cfg.user)", "Password: $($cfg.password)")
if ($bitLockerPassword) {
    $credentialText += "DataDisk: $($cfg.dataDiskLetter):"
    $credentialText += "DataDiskBitLockerPassword: $bitLockerPassword"
}
if ([bool]$streaming.enabled -and [bool]$streaming.installSunshine) {
    $credentialText += "SunshineUser: $($streaming.sunshineUser)"
    $credentialText += "SunshinePassword: $($streaming.sunshinePassword)"
}
Set-Content -LiteralPath (Join-Path $baseDir "credentials.txt") -Value $credentialText

Log "Resolving Windows ISO"
$windowsIso = WindowsIso $cfg $cacheDir
Log "Building unattended install media"
$media = InstallMedia $cfg $baseDir $windowsIso $sshKey $streaming

Log "Creating Hyper-V disks and VM"
New-VHD -Path $vhd -SizeBytes ([int64]$cfg.diskGB * 1GB) -Dynamic | Out-Null
New-VM -Name $cfg.vmName -Generation 2 -MemoryStartupBytes ([int64]$cfg.memoryGB * 1GB) -VHDPath $vhd -SwitchName $cfg.switchName | Out-Null
Set-VMProcessor -VMName $cfg.vmName -Count ([int]$cfg.cpuCount)
Set-VMMemory -VMName $cfg.vmName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $cfg.vmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Set-VM -Name $cfg.vmName -AutomaticCheckpointsEnabled $false -CheckpointType Standard
Set-VM -Name $cfg.vmName -EnhancedSessionTransportType VMBus
Set-VMKeyProtector -VMName $cfg.vmName -NewLocalKeyProtector
Enable-VMTPM -VMName $cfg.vmName

if (($displayWidth -gt 0) -and ($displayHeight -gt 0)) {
    Set-VMVideo -VMName $cfg.vmName -ResolutionType Single -HorizontalResolution $displayWidth -VerticalResolution $displayHeight
}

$bootDvd = Add-VMDvdDrive -VMName $cfg.vmName -Path $media.InstallIso -Passthru
Set-VMFirmware -VMName $cfg.vmName -FirstBootDevice $bootDvd
Log "Starting VM. Windows setup and first-login bootstrap can take a while"
Start-VM -Name $cfg.vmName

$ready = WaitForReady $cfg
Log "Initializing data disk"
InitializeDataDisk $cfg $dataVhd $bitLockerPassword
Log "Configuring Moonlight streaming stack"
RunRemoteStreamingSetup $cfg $streaming
Log "Applying GPU-PV settings"
$ready = ApplyGpuPv $cfg $gpu $baseDir
if (-not $ready) { $ready = WaitForReady $cfg }
Log "Writing connection files"
WriteConnectionInfo $cfg $streaming $baseDir
WriteRdpFile $configPath
Get-VM -Name $cfg.vmName | Select-Object Name, State, ProcessorCount, MemoryAssigned
Write-Host "Guest ready: $($ready.ComputerName)"
