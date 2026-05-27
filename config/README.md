# Config

Edit `windows.json` before running `create-workstation-vm.ps1`.

- `password`: leave empty to generate a random password. The generated login is written under `baseDir`.
- `switchName`: keep `Default Switch` for Hyper-V NAT. Use an external or bridged switch only when that is intentional.
- `baseDir`: stores the VM files, generated install media and `credentials.txt`.
- `imageCacheDir`: stores the downloaded Windows ISO cache.
- `recreate`: keep `false` by default. Set `true` only when replacing an existing VM and VHD is intentional.
- `windowsIsoPath`: leave empty to download Windows automatically. Set this to a local `.iso` path to use a manually downloaded image.
- `windowsRelease`, `windowsEdition`, `windowsLanguage`, `windowsArch`: used only when `windowsIsoPath` is empty.
- `windowsImageName`: must match an image name inside the ISO, for example `Windows 11 Pro`.
- `wingetPackages`: package IDs installed inside the VM on first login. Set to `[]` to install no extra tools.
