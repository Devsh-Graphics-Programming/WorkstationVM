$ErrorActionPreference = "Stop"; $scriptArgs = $args
Import-Module Microsoft.PowerShell.Security -ErrorAction SilentlyContinue

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

function Credentials($cfg) {
    $baseDir = FullPath $cfg.baseDir
    $file = Join-Path $baseDir "credentials.txt"
    $values = @{}
    if (Test-Path -LiteralPath $file) {
        Get-Content -LiteralPath $file | ForEach-Object {
            $parts = $_ -split ":", 2
            if ($parts.Count -eq 2) { $values[$parts[0].Trim()] = $parts[1].Trim() }
        }
    }

    if ([string]::IsNullOrWhiteSpace($cfg.password) -and $values.ContainsKey("Password")) {
        $cfg.password = $values["Password"]
    }
    return $values
}

function SshKeyPath($cfg) {
    Join-Path (FullPath $cfg.baseDir) "ssh_key_ed25519.key"
}

$configPath = ArgValue "config"
if ([string]::IsNullOrWhiteSpace($configPath)) {
    throw "Usage: .\check-workstation-vm.ps1 --config config\windows.json"
}

$cfg = Get-Content -Raw (FullPath $configPath) | ConvertFrom-Json
@{
    baseDir = "~/VMs/WorkstationW11"
    dataDiskGB = 24
    dataDiskLetter = "W"
    dataDiskLabel = "WorkData"
    dataDiskBitLocker = $true
    sshEnabled = $true
}.GetEnumerator() | ForEach-Object { Default $cfg $_.Key $_.Value }

$vm = Get-VM -Name $cfg.vmName -ErrorAction Stop

if ($vm.State -ne "Running") {
    throw "VM is not running: $($vm.State)"
}

Write-Host "VM running: $($vm.Name)"

if ([int]$cfg.dataDiskGB -gt 0) {
    $credentials = Credentials $cfg
    if ([string]::IsNullOrWhiteSpace($cfg.password)) { throw "Missing VM password in config or credentials.txt." }

    $secure = ConvertTo-SecureString $cfg.password -AsPlainText -Force
    $credential = [pscredential]::new($cfg.user, $secure)
    $state = Invoke-Command -VMName $cfg.vmName -Credential $credential -ArgumentList $cfg.dataDiskLetter, ([bool]$cfg.dataDiskBitLocker) -ScriptBlock {
        param($letter, $expectBitLocker)

        $letter = ([string]$letter).TrimEnd(":")
        $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
        $bitLocker = if ($expectBitLocker) { Get-BitLockerVolume -MountPoint "${letter}:" -ErrorAction Stop } else { $null }
        [pscustomobject]@{
            DriveLetter = $volume.DriveLetter
            FileSystemLabel = $volume.FileSystemLabel
            SizeGB = [math]::Round($volume.Size / 1GB, 2)
            BitLockerProtection = if ($bitLocker) { [string]$bitLocker.ProtectionStatus } else { "NotChecked" }
            BitLockerStatus = if ($bitLocker) { [string]$bitLocker.VolumeStatus } else { "NotChecked" }
        }
    }

    if ($state.DriveLetter -ne ([string]$cfg.dataDiskLetter).TrimEnd(":")) {
        throw "Unexpected data disk letter: $($state.DriveLetter)"
    }
    if ($state.FileSystemLabel -ne $cfg.dataDiskLabel) {
        throw "Unexpected data disk label: $($state.FileSystemLabel)"
    }
    if ([bool]$cfg.dataDiskBitLocker -and $state.BitLockerProtection -ne "On") {
        throw "Data disk BitLocker protection is not on: $($state.BitLockerProtection)"
    }
    if ([bool]$cfg.dataDiskBitLocker -and -not $credentials.ContainsKey("DataDiskBitLockerPassword")) {
        throw "credentials.txt does not contain DataDiskBitLockerPassword."
    }

    Write-Host "Data disk ready: $($state.DriveLetter): $($state.SizeGB) GB BitLocker=$($state.BitLockerProtection)"
}

if ([bool]$cfg.sshEnabled) {
    $key = SshKeyPath $cfg
    if (-not (Test-Path -LiteralPath $key)) { throw "Missing SSH private key: $key" }
    if ([string]::IsNullOrWhiteSpace($cfg.password)) { $null = Credentials $cfg }
    if ([string]::IsNullOrWhiteSpace($cfg.password)) { throw "Missing VM password in config or credentials.txt." }

    $secure = ConvertTo-SecureString $cfg.password -AsPlainText -Force
    $credential = [pscredential]::new($cfg.user, $secure)
    Invoke-Command -VMName $cfg.vmName -Credential $credential -ScriptBlock {
        $service = Get-Service sshd -ErrorAction Stop
        if ($service.Status -ne "Running") { throw "sshd is not running." }
        if (-not (Test-Path "$env:ProgramData\ssh\administrators_authorized_keys")) {
            throw "Missing administrators_authorized_keys."
        }
    }

    $ips = @(Get-VMNetworkAdapter -VMName $cfg.vmName |
        Select-Object -ExpandProperty IPAddresses |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -ne '0.0.0.0' })
    if (-not $ips) { throw "No usable VM IPv4 address found for SSH." }

    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) { throw "ssh.exe was not found on the host." }

    $ok = $false
    foreach ($ip in $ips) {
        & $ssh.Source -i $key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 "$($cfg.user)@$ip" "echo hello" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "SSH ready: $($cfg.user)@$ip"
            $ok = $true
            break
        }
    }
    if (-not $ok) { throw "SSH key login failed." }
}
