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

function Password {
    -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
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
    if (Test-Path $iso) { return $iso }

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

    Invoke-WebRequest -Uri $url -OutFile $iso
    return $iso
}

function InstallMedia($cfg, $baseDir, $windowsIso, $sshKey) {
    $dir = Join-Path $baseDir "answer"
    $installIso = Join-Path $baseDir "$($cfg.vmName)-install.iso"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $packages = @($cfg.wingetPackages) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    Set-Content -LiteralPath (Join-Path $dir "packages.txt") -Value $packages -Encoding UTF8
    [ordered]@{
        autoLogonUser = $cfg.user
        autoLogonPassword = $cfg.password
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir "bootstrap-config.json") -Encoding UTF8
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

function WaitForReady($cfg) {
    $credential = GuestCredential $cfg
    $deadline = (Get-Date).AddMinutes(90)

    while ((Get-Date) -lt $deadline) {
        try {
            $state = Invoke-Command -VMName $cfg.vmName -Credential $credential -ScriptBlock {
                $rdp = (Get-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server").fDenyTSConnections -eq 0
                [pscustomobject]@{
                    ComputerName = $env:COMPUTERNAME
                    BootstrapDone = Test-Path "C:\WorkstationVM\bootstrap.done"
                    RdpEnabled = $rdp
                }
            } -ErrorAction Stop

            if ($state.BootstrapDone -and $state.RdpEnabled) { return $state }
        } catch {
        }

        Start-Sleep -Seconds 30
    }

    throw "VM did not become ready within 90 minutes."
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
    diskGB = 100
    dataDiskGB = 24
    dataDiskLetter = "W"
    dataDiskLabel = "WorkData"
    dataDiskBitLocker = $true
    sshEnabled = $true
    displayWidth = ""
    displayHeight = ""
    recreate = $false
    wingetPackages = @("Microsoft.VisualStudioCode", "Git.Git", "WireGuard.WireGuard", "TorProject.TorBrowser")
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }

if ([string]::IsNullOrWhiteSpace($cfg.password)) { $cfg.password = Password }

$baseDir = FullPath $cfg.baseDir
$cacheDir = FullPath $cfg.imageCacheDir
$vmDir = Join-Path $baseDir "vm"
$vhd = Join-Path $vmDir "$($cfg.vmName).vhdx"
$dataVhd = Join-Path $vmDir "$($cfg.vmName)-data.vhdx"

New-Item -ItemType Directory -Force -Path $baseDir, $cacheDir, $vmDir | Out-Null

$existingVm = Get-VM -Name $cfg.vmName -ErrorAction SilentlyContinue
$existingDisk = Test-Path $vhd
$existingDataDisk = Test-Path $dataVhd
if ([bool]$cfg.recreate) {
    RemoveVm $cfg.vmName
    if ($existingDisk) { Remove-Item -LiteralPath $vhd -Force }
    if ($existingDataDisk) { Remove-Item -LiteralPath $dataVhd -Force }
} elseif ($existingVm -or $existingDisk -or $existingDataDisk) {
    throw "VM or disk already exists. Set recreate to true only when you intentionally want to replace it."
}

$bitLockerPassword = ""
if ((Number $cfg.dataDiskGB) -gt 0 -and [bool]$cfg.dataDiskBitLocker) { $bitLockerPassword = BitLockerPassword }
$sshKey = EnsureSshKey $cfg $baseDir

$credentialText = @("User: $($cfg.user)", "Password: $($cfg.password)")
if ($bitLockerPassword) {
    $credentialText += "DataDisk: $($cfg.dataDiskLetter):"
    $credentialText += "DataDiskBitLockerPassword: $bitLockerPassword"
}
Set-Content -LiteralPath (Join-Path $baseDir "credentials.txt") -Value $credentialText

$windowsIso = WindowsIso $cfg $cacheDir
$media = InstallMedia $cfg $baseDir $windowsIso $sshKey

New-VHD -Path $vhd -SizeBytes ([int64]$cfg.diskGB * 1GB) -Dynamic | Out-Null
New-VM -Name $cfg.vmName -Generation 2 -MemoryStartupBytes ([int64]$cfg.memoryGB * 1GB) -VHDPath $vhd -SwitchName $cfg.switchName | Out-Null
Set-VMProcessor -VMName $cfg.vmName -Count ([int]$cfg.cpuCount)
Set-VMMemory -VMName $cfg.vmName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $cfg.vmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Set-VM -Name $cfg.vmName -AutomaticCheckpointsEnabled $false -CheckpointType Standard
Set-VM -Name $cfg.vmName -EnhancedSessionTransportType VMBus
Set-VMKeyProtector -VMName $cfg.vmName -NewLocalKeyProtector
Enable-VMTPM -VMName $cfg.vmName

$displayWidth = Number $cfg.displayWidth
$displayHeight = Number $cfg.displayHeight
if (($displayWidth -le 0) -or ($displayHeight -le 0)) {
    $display = HostDisplay
    if ($displayWidth -le 0) { $displayWidth = $display.Width }
    if ($displayHeight -le 0) { $displayHeight = $display.Height }
}
if (($displayWidth -gt 0) -and ($displayHeight -gt 0)) {
    Set-VMVideo -VMName $cfg.vmName -ResolutionType Single -HorizontalResolution $displayWidth -VerticalResolution $displayHeight
}

$bootDvd = Add-VMDvdDrive -VMName $cfg.vmName -Path $media.InstallIso -Passthru
Set-VMFirmware -VMName $cfg.vmName -FirstBootDevice $bootDvd
Start-VM -Name $cfg.vmName

$ready = WaitForReady $cfg
InitializeDataDisk $cfg $dataVhd $bitLockerPassword
Get-VM -Name $cfg.vmName | Select-Object Name, State, ProcessorCount, MemoryAssigned
Write-Host "Guest ready: $($ready.ComputerName)"
