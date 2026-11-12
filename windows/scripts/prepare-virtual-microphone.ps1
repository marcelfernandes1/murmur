# Test infrastructure only. This driver is never included in Murmur's installer.
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This setup script is only for a disposable GitHub Actions runner.' }
New-Item -ItemType Directory -Force $Output | Out-Null
# The hosted Windows Server image denies capture by default. Grant access only
# on this disposable runner, whose only input is the prerecorded virtual cable.
foreach ($hive in @('HKLM:', 'HKCU:')) {
    $consent = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"
    foreach ($path in @($consent, "$consent\NonPackaged")) {
        New-Item $path -Force | Out-Null
        New-ItemProperty $path -Name Value -Value Allow -PropertyType String -Force | Out-Null
    }
}
Set-Service AudioEndpointBuilder -StartupType Automatic
Set-Service Audiosrv -StartupType Automatic
Start-Service AudioEndpointBuilder
Start-Service Audiosrv
$zip = Join-Path $Output 'vbcable.zip'
Invoke-WebRequest 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip' -OutFile $zip
if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne 'B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB') { throw 'Virtual audio driver checksum mismatch.' }
$driver = Join-Path $Output 'vbcable'
Expand-Archive $zip $driver -Force
$installer = Join-Path $driver 'VBCABLE_Setup_x64.exe'
$signature = Get-AuthenticodeSignature $installer
if ($signature.Status -ne 'Valid') { throw 'Virtual audio installer is not validly signed.' }
$process = Start-Process $installer -ArgumentList '-i', '-h' -PassThru
if (!$process.WaitForExit(90000)) { Stop-Process -Id $process.Id -Force; throw 'Virtual audio installation timed out.' }
"Installer exit code: $($process.ExitCode)" | Write-Host
pnputil /scan-devices
Start-Sleep -Seconds 4
Get-PnpDevice -Class Media | Select-Object Status, FriendlyName | Format-Table
