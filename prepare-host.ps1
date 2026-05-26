#Requires -RunAsAdministrator
param(
    [string]$User = "$env:USERDOMAIN\$env:USERNAME"
)

$ErrorActionPreference = "Stop"

function AssertFirmwareVirtualization {
    $system = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($system -and $system.HypervisorPresent) { return }

    $processors = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
    if (-not $processors) { return }

    $firmwareStates = @($processors | ForEach-Object { $_.VirtualizationFirmwareEnabled })
    if (($firmwareStates.Count -gt 0) -and ($firmwareStates -contains $false)) {
        throw "Hardware virtualization is disabled in BIOS/UEFI. Enable Intel VT-x, AMD-V or SVM, then restart Windows."
    }

    if (@($processors | ForEach-Object { $_.VMMonitorModeExtensions }) -contains $false) {
        throw "CPU does not report VM monitor extensions required by Hyper-V."
    }
    if (@($processors | ForEach-Object { $_.SecondLevelAddressTranslationExtensions }) -contains $false) {
        throw "CPU does not report SLAT support required by Hyper-V."
    }
}

function EnableFeature($name) {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction SilentlyContinue
    if (-not $feature) {
        if (Get-Module -ListAvailable -Name Hyper-V) { return }
        throw "Windows optional feature '$name' was not found. This Windows edition may not support Hyper-V."
    }
    if ($feature.State -ne "Enabled") {
        Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart | Out-Null
        $script:featureChanged = $true
    }
}

function HyperVGroup {
    $sid = [Security.Principal.SecurityIdentifier]"S-1-5-32-578"
    $sid.Translate([Security.Principal.NTAccount]).Value.Split("\")[-1]
}

function Oscdimg {
    $tool = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($tool) { return $tool.Source }

    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits",
        "$env:ProgramFiles\Windows Kits"
    ) | Where-Object { Test-Path $_ }

    Get-ChildItem -Path $roots -Recurse -Filter oscdimg.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

function InstallAdkDeploymentTools {
    if (Oscdimg) { return }

    $dir = Join-Path $env:TEMP "WorkstationVM"
    $setup = Join-Path $dir "adksetup.exe"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/?linkid=2289980" -OutFile $setup
    $process = Start-Process -FilePath $setup -ArgumentList "/quiet", "/norestart", "/features", "OptionId.DeploymentTools" -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Windows ADK install failed with exit code $($process.ExitCode)." }
    if (-not (Oscdimg)) { throw "Windows ADK installed, but oscdimg.exe was not found." }
}

$featureChanged = $false
$groupChanged = $false

AssertFirmwareVirtualization
EnableFeature "Microsoft-Hyper-V-All"
& bcdedit.exe /set hypervisorlaunchtype auto | Out-Null

$group = HyperVGroup
$members = Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name.ToLowerInvariant() }
if ($members -notcontains $User.ToLowerInvariant()) {
    Add-LocalGroupMember -Group $group -Member $User
    $groupChanged = $true
}

InstallAdkDeploymentTools

if (-not (Get-VMSwitch -Name "Default Switch" -ErrorAction SilentlyContinue)) {
    $featureChanged = $true
}

if ($featureChanged) {
    "Host prepared. Restart Windows before creating the VM."
} elseif ($groupChanged) {
    "Host prepared. Sign out and back in, then use normal PowerShell."
} else {
    "Host is ready. Use normal PowerShell to create the VM."
}
