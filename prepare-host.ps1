#Requires -RunAsAdministrator
param(
    [string]$User = "$env:USERDOMAIN\$env:USERNAME"
)

$ErrorActionPreference = "Stop"

function EnableFeature($name) {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $name
    if ($feature.State -ne "Enabled") {
        Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart | Out-Null
        $script:restartNeeded = $true
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

$restartNeeded = $false

EnableFeature "Microsoft-Hyper-V-All"
& bcdedit.exe /set hypervisorlaunchtype auto | Out-Null

$group = HyperVGroup
$members = Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name.ToLowerInvariant() }
if ($members -notcontains $User.ToLowerInvariant()) {
    Add-LocalGroupMember -Group $group -Member $User
    $restartNeeded = $true
}

if (-not (Oscdimg)) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "winget.exe is required to install Windows ADK Deployment Tools."
    }

    & winget.exe install --id Microsoft.WindowsADK --exact --silent --accept-package-agreements --accept-source-agreements --override "/quiet /features OptionId.DeploymentTools"
    if ($LASTEXITCODE -ne 0) { throw "Windows ADK install failed." }
}

if (-not (Get-VMSwitch -Name "Default Switch" -ErrorAction SilentlyContinue)) {
    $restartNeeded = $true
}

if ($restartNeeded) {
    "Host prepared. Restart Windows or sign out and back in before creating the VM."
} else {
    "Host is ready."
}
