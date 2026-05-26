$ErrorActionPreference = "Continue"

$root = "C:\WorkstationVM"
$log = Join-Path $root "bootstrap.log"
New-Item -ItemType Directory -Force -Path $root | Out-Null
Start-Transcript -Path $log -Append | Out-Null

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
