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

function Xml($text) {
    [Security.SecurityElement]::Escape([string]$text)
}

function RemoveVm($name) {
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if ($vm) {
        Stop-VM -Name $name -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $name -Force
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

function InstallMedia($cfg, $baseDir, $windowsIso) {
    $dir = Join-Path $baseDir "answer"
    $installIso = Join-Path $baseDir "$($cfg.vmName)-install.iso"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $packages = @($cfg.wingetPackages) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    Set-Content -LiteralPath (Join-Path $dir "packages.txt") -Value $packages -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "bootstrap-windows.ps1") -Destination $dir -Force

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
    $password = ConvertTo-SecureString $cfg.password -AsPlainText -Force
    $credential = [pscredential]::new($cfg.user, $password)
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
    recreate = $false
    wingetPackages = @("Microsoft.VisualStudioCode", "Git.Git", "WireGuard.WireGuard")
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }

if ([string]::IsNullOrWhiteSpace($cfg.password)) { $cfg.password = Password }

$baseDir = FullPath $cfg.baseDir
$cacheDir = FullPath $cfg.imageCacheDir
$vmDir = Join-Path $baseDir "vm"
$vhd = Join-Path $vmDir "$($cfg.vmName).vhdx"

New-Item -ItemType Directory -Force -Path $baseDir, $cacheDir, $vmDir | Out-Null

$existingVm = Get-VM -Name $cfg.vmName -ErrorAction SilentlyContinue
$existingDisk = Test-Path $vhd
if ([bool]$cfg.recreate) {
    RemoveVm $cfg.vmName
    if ($existingDisk) { Remove-Item -LiteralPath $vhd -Force }
} elseif ($existingVm -or $existingDisk) {
    throw "VM or disk already exists. Set recreate to true only when you intentionally want to replace it."
}

Set-Content -LiteralPath (Join-Path $baseDir "credentials.txt") -Value "User: $($cfg.user)`nPassword: $($cfg.password)`n"

$windowsIso = WindowsIso $cfg $cacheDir
$media = InstallMedia $cfg $baseDir $windowsIso

New-VHD -Path $vhd -SizeBytes ([int64]$cfg.diskGB * 1GB) -Dynamic | Out-Null
New-VM -Name $cfg.vmName -Generation 2 -MemoryStartupBytes ([int64]$cfg.memoryGB * 1GB) -VHDPath $vhd -SwitchName $cfg.switchName | Out-Null
Set-VMProcessor -VMName $cfg.vmName -Count ([int]$cfg.cpuCount)
Set-VMMemory -VMName $cfg.vmName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $cfg.vmName -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Set-VM -Name $cfg.vmName -AutomaticCheckpointsEnabled $false -CheckpointType Standard
Set-VMKeyProtector -VMName $cfg.vmName -NewLocalKeyProtector
Enable-VMTPM -VMName $cfg.vmName

$bootDvd = Add-VMDvdDrive -VMName $cfg.vmName -Path $media.InstallIso -Passthru
Set-VMFirmware -VMName $cfg.vmName -FirstBootDevice $bootDvd
Start-VM -Name $cfg.vmName

$ready = WaitForReady $cfg
Get-VM -Name $cfg.vmName | Select-Object Name, State, ProcessorCount, MemoryAssigned
Write-Host "Guest ready: $($ready.ComputerName)"
