$ErrorActionPreference = "Continue"

$root = "C:\WorkstationVM"
$log = Join-Path $root "bootstrap.log"
New-Item -ItemType Directory -Force -Path $root | Out-Null
Start-Transcript -Path $log -Append | Out-Null

function EnableRemoteDesktop {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Type DWord -Value 0
    Set-Service -Name TermService -StartupType Automatic
    Start-Service -Name TermService

    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
    Set-NetFirewallRule -Name "RemoteDesktop-UserMode-In-TCP", "RemoteDesktop-UserMode-In-UDP" -Enabled True -ErrorAction SilentlyContinue

    try {
        $group = ([Security.Principal.SecurityIdentifier]"S-1-5-32-555").Translate([Security.Principal.NTAccount]).Value.Split("\")[-1]
        Add-LocalGroupMember -Group $group -Member $env:USERNAME -ErrorAction SilentlyContinue
    } catch {
        "Remote Desktop user setup failed: $_" | Out-File -FilePath $log -Append
    }
}

EnableRemoteDesktop

$media = Get-PSDrive -PSProvider FileSystem |
    Where-Object { Test-Path (Join-Path $_.Root "packages.txt") } |
    Select-Object -First 1

$packages = @()
if ($media) {
    $packages = Get-Content -LiteralPath (Join-Path $media.Root "packages.txt") |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

for ($i = 0; $i -lt 60; $i++) {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) { break }
    Start-Sleep -Seconds 10
}

if (-not $winget) {
    "winget.exe was not found." | Out-File -FilePath $log -Append
    Stop-Transcript | Out-Null
    exit 1
}

foreach ($package in $packages) {
    & winget.exe install --id $package --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        "Install failed: $package ($LASTEXITCODE)" | Out-File -FilePath $log -Append
    }
}

"Done" | Set-Content -LiteralPath (Join-Path $root "bootstrap.done")
Stop-Transcript | Out-Null
