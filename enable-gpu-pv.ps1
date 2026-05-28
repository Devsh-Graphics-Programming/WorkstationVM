$ErrorActionPreference = "Stop"; $scriptArgs = $args

function ArgValue($name) {
    for ($i = 0; $i -lt $scriptArgs.Count; $i++) {
        if ($scriptArgs[$i] -in @("-$name", "--$name")) { return $scriptArgs[$i + 1] }
    }
    return ""
}

function ArgSwitch($name) {
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

function ConfigValue($cfg, $name, $defaultValue) {
    if ($null -eq $cfg -or $null -eq $cfg.$name) { return $defaultValue }
    return $cfg.$name
}

function LoadGpuConfig($path) {
    $raw = Get-Content -Raw (FullPath $path) | ConvertFrom-Json

    if ($null -ne $raw.gpu -or $null -ne $raw.gpuPv) {
        $gpu = if ($null -ne $raw.gpu) { $raw.gpu } else { $raw.gpuPv }
        $baseDir = FullPath (ConfigValue $raw "baseDir" "~/VMs/WorkstationWindows11")
        $cfg = [pscustomobject]@{
            enabled = ConfigValue $gpu "enabled" $true
            vmName = ConfigValue $raw "vmName" "WorkstationW11"
            credentialsPath = Join-Path $baseDir "credentials.txt"
            gpuName = ConfigValue $gpu "gpuName" "AUTO"
            allocationPercent = ConfigValue $gpu "allocationPercent" 25
        }
        return $cfg
    }

    Default $raw "enabled" $true
    Default $raw "vmName" "WorkstationW11"
    Default $raw "baseDir" "~/VMs/WorkstationWindows11"
    Default $raw "credentialsPath" (Join-Path (FullPath $raw.baseDir) "credentials.txt")
    Default $raw "gpuName" "AUTO"
    Default $raw "allocationPercent" 25
    return $raw
}

function PciIdFromPartitionableGpu($name) {
    if ([string]$name -match 'PCI#(.+?)#\{') { return "PCI\" + $Matches[1].Replace("#", "\") }
    return ""
}

function ResolveGpu($gpuName) {
    $partitionable = @(Get-VMHostPartitionableGpu)
    if ($partitionable.Count -eq 0) { throw "No partitionable GPU was reported by Hyper-V." }

    $controllers = @(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID })
    if ($gpuName -eq "AUTO") {
        foreach ($gpu in $partitionable) {
            $pciId = PciIdFromPartitionableGpu $gpu.Name
            $controller = $controllers | Where-Object { $_.PNPDeviceID -ieq $pciId } | Select-Object -First 1
            if ($controller) {
                return [pscustomobject]@{ PartitionableGpu = $gpu; Controller = $controller; PciId = $pciId }
            }
        }
        throw "Could not map any partitionable GPU to a display controller."
    }

    $controller = $controllers | Where-Object { $_.Name -eq $gpuName } | Select-Object -First 1
    if (-not $controller) { throw "GPU '$gpuName' was not found. Use AUTO or one of the Win32_VideoController names." }

    $gpuMatch = $partitionable | Where-Object { (PciIdFromPartitionableGpu $_.Name) -ieq $controller.PNPDeviceID } | Select-Object -First 1
    if (-not $gpuMatch) { throw "GPU '$gpuName' is not exposed as partitionable by Hyper-V." }

    [pscustomobject]@{ PartitionableGpu = $gpuMatch; Controller = $controller; PciId = $controller.PNPDeviceID }
}

function PartitionValue($total, $percent) {
    $number = [decimal]([string]$total)
    if ($number -le 0) { return [uint64]0 }
    $value = [decimal]::Floor($number * [decimal]$percent / 100)
    if ($value -lt 1) { $value = 1 }
    return [uint64]$value
}

function SecureText($text) {
    $secure = [Security.SecureString]::new()
    foreach ($ch in ([string]$text).ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return $secure
}

function GuestCredential($cfg) {
    $path = FullPath $cfg.credentialsPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Credentials file '$path' was not found. Shut down the VM manually or set credentialsPath in the GPU config."
    }
    $content = Get-Content -LiteralPath $path
    $userLine = $content | Where-Object { $_ -match '^User:\s*(.+)$' } | Select-Object -First 1
    $passwordLine = $content | Where-Object { $_ -match '^Password:\s*(.+)$' } | Select-Object -First 1
    if (-not $userLine -or -not $passwordLine) { throw "Credentials file '$path' does not contain User and Password lines." }
    $user = [regex]::Match($userLine, '^User:\s*(.+)$').Groups[1].Value
    $password = [regex]::Match($passwordLine, '^Password:\s*(.+)$').Groups[1].Value
    [pscredential]::new($user, (SecureText $password))
}

function StopVmGracefully($cfg) {
    $vmName = $cfg.vmName
    $vm = Get-VM -Name $vmName -ErrorAction Stop
    $wasRunning = $vm.State -eq "Running"
    if ($vm.State -ne "Off") {
        Write-Host "Shutting down VM '$vmName'..."
        $credential = GuestCredential $cfg
        $shutdownRequested = $false
        $deadline = (Get-Date).AddMinutes(5)
        do {
            try {
                Invoke-Command -VMName $vmName -Credential $credential -ScriptBlock {
                    Stop-Computer -Force
                } -ErrorAction Stop | Out-Null
                $shutdownRequested = $true
                break
            } catch {
                Start-Sleep -Seconds 5
                $vm = Get-VM -Name $vmName
                if ($vm.State -eq "Off") {
                    $shutdownRequested = $true
                    break
                }
            }
        } while ((Get-Date) -lt $deadline)
        if (-not $shutdownRequested) { throw "Could not request a clean shutdown for VM '$vmName' through PowerShell Direct." }

        do {
            Start-Sleep -Seconds 3
            $vm = Get-VM -Name $vmName
        } while ($vm.State -ne "Off" -and (Get-Date) -lt $deadline)
        if ($vm.State -ne "Off") { throw "VM '$vmName' did not shut down cleanly. No forced power-off was used." }
    }
    return $wasRunning
}

function StartVmIfNeeded($vmName, $wasRunning) {
    if (-not $wasRunning) { return }
    Write-Host "Starting VM '$vmName'..."
    Start-VM -Name $vmName
}

function SystemVhdPath($vmName) {
    $disk = Get-VMHardDiskDrive -VMName $vmName |
        Sort-Object ControllerNumber, ControllerLocation |
        Select-Object -First 1
    if (-not $disk) { throw "VM '$vmName' does not have a hard disk." }
    return $disk.Path
}

function GpuStatePath($systemVhd) {
    Join-Path (Split-Path -Parent $systemVhd) "gpu-pv-state.json"
}

function SaveVmState($vmName, $statePath) {
    if (Test-Path -LiteralPath $statePath) { return }
    $vm = Get-VM -Name $vmName
    $processor = Get-VMProcessor -VMName $vmName
    [ordered]@{
        guestControlledCacheTypes = [bool]$vm.GuestControlledCacheTypes
        lowMemoryMappedIoSpace = [uint64]$vm.LowMemoryMappedIoSpace
        highMemoryMappedIoSpace = [uint64]$vm.HighMemoryMappedIoSpace
        exposeVirtualizationExtensions = [bool]$processor.ExposeVirtualizationExtensions
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function RestoreVmState($vmName, $statePath) {
    if (-not (Test-Path -LiteralPath $statePath)) { return }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    Set-VM -Name $vmName `
        -GuestControlledCacheTypes ([bool]$state.guestControlledCacheTypes) `
        -LowMemoryMappedIoSpace ([uint64]$state.lowMemoryMappedIoSpace) `
        -HighMemoryMappedIoSpace ([uint64]$state.highMemoryMappedIoSpace)
    Set-VMProcessor -VMName $vmName -ExposeVirtualizationExtensions ([bool]$state.exposeVirtualizationExtensions)
}

function DriverStoreDestination($guestRoot, $sourcePath) {
    if ($sourcePath -match '^[a-z]:\\windows\\system32\\driverstore\\filerepository\\([^\\]+)') {
        return Join-Path $guestRoot "Windows\System32\HostDriverStore\FileRepository\$($Matches[1])"
    }
    return $null
}

function PackageDestination($packageRoot, $destination) {
    if ($destination -notmatch '^[a-z]:\\(.+)$') { throw "Destination '$destination' is not an absolute Windows path." }
    return Join-Path $packageRoot $Matches[1]
}

function CopyDirectoryContents($packageRoot, $source, $destination) {
    $target = PackageDestination $packageRoot $destination
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force
}

function CopyFileToPackage($packageRoot, $source, $destination) {
    $target = PackageDestination $packageRoot $destination
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
}

function CopyGpuDrivers($packageRoot, $guestRoot, $gpu) {
    $drivers = @(Get-WmiObject Win32_PNPSignedDriver | Where-Object {
        $_.DeviceID -ieq $gpu.PciId -or $_.DeviceName -eq $gpu.Controller.Name
    })
    if ($drivers.Count -eq 0) { throw "Could not find host GPU driver metadata for '$($gpu.Controller.Name)'." }

    $copiedDirectories = @{}
    $copiedFiles = 0

    $pnp = Get-PnpDevice | Where-Object { $_.InstanceId -ieq $gpu.PciId } | Select-Object -First 1
    if ($pnp -and $pnp.Service) {
        $service = Get-WmiObject Win32_SystemDriver | Where-Object { $_.Name -eq $pnp.Service } | Select-Object -First 1
        if ($service -and $service.PathName) {
            $serviceFile = ([string]$service.PathName).Trim('"')
            if (Test-Path -LiteralPath $serviceFile) {
                $serviceDestination = DriverStoreDestination $guestRoot $serviceFile.ToLowerInvariant()
                if ($serviceDestination) {
                    $serviceSource = Split-Path -Parent $serviceFile
                    if (-not $copiedDirectories.ContainsKey($serviceDestination)) {
                        CopyDirectoryContents $packageRoot $serviceSource $serviceDestination
                        $copiedDirectories[$serviceDestination] = $true
                    }
                }
            }
        }
    }

    foreach ($driver in $drivers) {
        $deviceId = $driver.DeviceID.Replace("\", "\\")
        $antecedent = "\\" + $env:COMPUTERNAME + "\ROOT\cimv2:Win32_PNPSignedDriver.DeviceID=`"$deviceId`""
        $driverFiles = @(Get-WmiObject Win32_PNPSignedDriverCIMDataFile | Where-Object { $_.Antecedent -eq $antecedent })
        foreach ($file in $driverFiles) {
            $sourcePath = ($file.Dependent.Split("=")[1] -replace "\\\\", "\").Trim('"')
            if (-not (Test-Path -LiteralPath $sourcePath)) { continue }

            $driverStoreDestination = DriverStoreDestination $guestRoot $sourcePath.ToLowerInvariant()
            if ($driverStoreDestination) {
                $sourceDirectory = Split-Path -Parent $sourcePath
                if (-not $copiedDirectories.ContainsKey($driverStoreDestination)) {
                    CopyDirectoryContents $packageRoot $sourceDirectory $driverStoreDestination
                    $copiedDirectories[$driverStoreDestination] = $true
                }
                continue
            }

            if ($sourcePath -match '^[a-z]:\\(.+)$') {
                $destination = Join-Path $guestRoot $Matches[1]
                CopyFileToPackage $packageRoot $sourcePath $destination
                $copiedFiles++
            }
        }
    }

    [pscustomobject]@{
        DriverStoreDirectories = $copiedDirectories.Count
        Files = $copiedFiles
    }
}

function CopyGpuDriversOnline($cfg, $gpu) {
    $vm = Get-VM -Name $cfg.vmName
    if ($vm.State -ne "Running") { throw "VM '$($cfg.vmName)' must be running so driver files can be copied through Hyper-V Guest Service." }
    $service = Get-VMIntegrationService -VMName $cfg.vmName -Name "Guest Service Interface"
    $wasEnabled = [bool]$service.Enabled
    $packageRoot = Join-Path ([IO.Path]::GetTempPath()) ("WorkstationVM-GpuPv-" + [guid]::NewGuid().ToString("N"))
    $zipPath = "$packageRoot.zip"
    $guestZipPath = "C:\WorkstationVM\gpu-pv-driver.zip"
    Write-Host "Packaging GPU driver files for '$($gpu.Controller.Name)'..."
    try {
        New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
        $summary = CopyGpuDrivers $packageRoot "C:\" $gpu
        Compress-Archive -Path (Join-Path $packageRoot "*") -DestinationPath $zipPath -Force
        if (-not $wasEnabled) { Enable-VMIntegrationService -VMName $cfg.vmName -Name "Guest Service Interface" }
        Write-Host "Copying packaged driver files through Hyper-V Guest Service..."
        Copy-VMFile -Name $cfg.vmName -SourcePath $zipPath -DestinationPath $guestZipPath -FileSource Host -CreateFullPath -Force
        Invoke-Command -VMName $cfg.vmName -Credential (GuestCredential $cfg) -ArgumentList $guestZipPath -ScriptBlock {
            param($zip)
            Expand-Archive -LiteralPath $zip -DestinationPath "C:\" -Force
            Remove-Item -LiteralPath $zip -Force
        } | Out-Null
        return $summary
    } finally {
        if (-not $wasEnabled) { Disable-VMIntegrationService -VMName $cfg.vmName -Name "Guest Service Interface" }
        if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force }
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    }
}

function SetGpuPartitionAllocation($vmName, $gpu, $percent) {
    $adapter = @(Get-VMGpuPartitionAdapter -VMName $vmName)
    if ($adapter.Count -gt 1) { throw "VM '$vmName' has more than one GPU partition adapter. Remove extras manually before using this helper." }
    if ($adapter.Count -eq 0) {
        Add-VMGpuPartitionAdapter -VMName $vmName -InstancePath $gpu.PartitionableGpu.Name | Out-Null
    }

    $resources = @{
        MinPartitionVRAM = PartitionValue $gpu.PartitionableGpu.TotalVRAM $percent
        MaxPartitionVRAM = PartitionValue $gpu.PartitionableGpu.TotalVRAM $percent
        OptimalPartitionVRAM = PartitionValue $gpu.PartitionableGpu.TotalVRAM $percent
        MinPartitionEncode = PartitionValue $gpu.PartitionableGpu.TotalEncode $percent
        MaxPartitionEncode = PartitionValue $gpu.PartitionableGpu.TotalEncode $percent
        OptimalPartitionEncode = PartitionValue $gpu.PartitionableGpu.TotalEncode $percent
        MinPartitionDecode = PartitionValue $gpu.PartitionableGpu.TotalDecode $percent
        MaxPartitionDecode = PartitionValue $gpu.PartitionableGpu.TotalDecode $percent
        OptimalPartitionDecode = PartitionValue $gpu.PartitionableGpu.TotalDecode $percent
        MinPartitionCompute = PartitionValue $gpu.PartitionableGpu.TotalCompute $percent
        MaxPartitionCompute = PartitionValue $gpu.PartitionableGpu.TotalCompute $percent
        OptimalPartitionCompute = PartitionValue $gpu.PartitionableGpu.TotalCompute $percent
    }
    Set-VMGpuPartitionAdapter -VMName $vmName @resources
}

function EnableGpuPv($cfg, $gpu) {
    $adapter = @(Get-VMGpuPartitionAdapter -VMName $cfg.vmName)
    if ($adapter.Count -eq 0) {
        CopyGpuDriversOnline $cfg $gpu | Format-List | Out-String | Write-Host
    } else {
        Write-Host "GPU-PV adapter already exists. Updating allocation without refreshing driver files."
    }
    $systemVhd = SystemVhdPath $cfg.vmName
    $statePath = GpuStatePath $systemVhd
    SaveVmState $cfg.vmName $statePath
    $wasRunning = StopVmGracefully $cfg
    try {
        Set-VM -Name $cfg.vmName -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 3GB -HighMemoryMappedIoSpace 32GB
        Set-VMProcessor -VMName $cfg.vmName -ExposeVirtualizationExtensions $true
        SetGpuPartitionAllocation $cfg.vmName $gpu ([int]$cfg.allocationPercent)
    } finally {
        StartVmIfNeeded $cfg.vmName $wasRunning
    }
}

function DisableGpuPv($cfg) {
    $systemVhd = SystemVhdPath $cfg.vmName
    $statePath = GpuStatePath $systemVhd
    $wasRunning = StopVmGracefully $cfg
    try {
        $adapter = @(Get-VMGpuPartitionAdapter -VMName $cfg.vmName)
        foreach ($item in $adapter) { Remove-VMGpuPartitionAdapter -VMGpuPartitionAdapter $item }
        RestoreVmState $cfg.vmName $statePath
    } finally {
        StartVmIfNeeded $cfg.vmName $wasRunning
    }
}

$configPath = ArgValue "config"
if ([string]::IsNullOrWhiteSpace($configPath)) {
    throw "Usage: .\enable-gpu-pv.ps1 --config config\windows.json [--check] [--disable]"
}

$cfg = LoadGpuConfig $configPath

$cfg.gpuName = ([string]$cfg.gpuName).Trim()
if ([string]::IsNullOrWhiteSpace($cfg.gpuName)) { $cfg.gpuName = "AUTO" }
$cfg.allocationPercent = [int]$cfg.allocationPercent
if ($cfg.allocationPercent -lt 1 -or $cfg.allocationPercent -gt 100) { throw "allocationPercent must be between 1 and 100." }

$vm = Get-VM -Name $cfg.vmName -ErrorAction Stop
if ($vm.Generation -ne 2) { throw "GPU-PV requires a Generation 2 VM." }

$gpu = ResolveGpu $cfg.gpuName
$adapter = @(Get-VMGpuPartitionAdapter -VMName $cfg.vmName)

if (ArgSwitch "check") {
    [pscustomobject]@{
        VMName = $cfg.vmName
        VMState = $vm.State
        GPUName = $gpu.Controller.Name
        GPUPciId = $gpu.PciId
        Enabled = [bool]$cfg.enabled
        AllocationPercent = $cfg.allocationPercent
        ExistingGpuPartitionAdapters = $adapter.Count
    } | Format-List
    return
}

if (ArgSwitch "disable") {
    DisableGpuPv $cfg
    Write-Host "GPU-PV disabled for VM '$($cfg.vmName)'."
    return
}

if (-not [bool]$cfg.enabled) {
    throw "GPU-PV is disabled in the config. Set gpu.enabled to true before applying it."
}

EnableGpuPv $cfg $gpu
Write-Host "GPU-PV enabled for VM '$($cfg.vmName)' using '$($gpu.Controller.Name)' at $($cfg.allocationPercent)%."
