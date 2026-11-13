param([Parameter(Mandatory)][string]$InstallerPath, [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This acceptance test is only for a disposable GitHub Actions runner.' }
$Output = [IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force $Output | Out-Null
$installed = Join-Path $env:RUNNER_TEMP "murmur-install-$([guid]::NewGuid())"
$process = Start-Process $InstallerPath -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', "/DIR=`"$installed`"", "/LOG=`"$Output/install.log`"") -PassThru
if (!$process.WaitForExit(120000)) { Stop-Process -Id $process.Id -Force; throw 'Installer timed out.' }
if ($process.ExitCode -ne 0) { throw "Installer failed: $($process.ExitCode)" }
foreach ($file in @('Murmur.exe', 'Cleanup/Murmur.Cleanup.exe', 'unins000.exe', 'LICENSE')) {
    if (!(Test-Path (Join-Path $installed $file))) { throw "Installed package is missing $file" }
}
& "$PSScriptRoot/smoke-test.ps1" -AppPath "$installed/Murmur.exe" -Output $Output
$data = Join-Path $env:LOCALAPPDATA 'Murmur'
New-Item -ItemType Directory -Force $data | Out-Null
$sentinel = Join-Path $data "installer-retention-$([guid]::NewGuid()).txt"
'Preserve local history and models when uninstalling.' | Set-Content $sentinel
try {
    $uninstall = Start-Process "$installed/unins000.exe" -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$Output/uninstall.log`"") -PassThru
    if (!$uninstall.WaitForExit(60000)) { Stop-Process -Id $uninstall.Id -Force; throw 'Uninstaller timed out.' }
    if ($uninstall.ExitCode -ne 0) { throw "Uninstaller failed: $($uninstall.ExitCode)" }
    if (Test-Path "$installed/Murmur.exe") { throw 'Uninstall left the application executable behind.' }
    if (!(Test-Path $sentinel)) { throw 'Uninstall deleted user data.' }
    'PASS: silent installation, installed app startup, single instance, uninstall, and local-data retention.' | Set-Content "$Output/installer-results.txt"
} finally { Remove-Item $sentinel -ErrorAction SilentlyContinue }
