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
        $script:restartNeeded = $true
    }
}

function HyperVGroup {
    $sid = [Security.Principal.SecurityIdentifier]"S-1-5-32-578"
    $sid.Translate([Security.Principal.NTAccount]).Value.Split("\")[-1]
}

$restartNeeded = $false
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

if ($restartNeeded) {
    "Host prepared. Restart Windows before creating the VM."
} elseif ($groupChanged) {
    "Host prepared. Sign out and back in, then use normal PowerShell."
} else {
    "Host is ready. Use normal PowerShell to create the VM."
}
