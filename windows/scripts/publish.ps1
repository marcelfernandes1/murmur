param([string]$Output = (Join-Path $PSScriptRoot '../artifacts'), [switch]$Installer)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$Output = [IO.Path]::GetFullPath($Output)
$app = Join-Path $Output 'Murmur-win-x64'
New-Item -ItemType Directory -Force -Path $app | Out-Null
dotnet publish "$root/Murmur.Windows/Murmur.Windows.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -o $app
if ($LASTEXITCODE -ne 0) { throw 'Windows publish failed.' }
dotnet publish "$root/Murmur.Cleanup/Murmur.Cleanup.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -o "$app/Cleanup"
if ($LASTEXITCODE -ne 0) { throw 'Cleanup publish failed.' }
Copy-Item "$root/README.md" "$app/README.md"
Copy-Item "$root/THIRD-PARTY-NOTICES.md" "$app/THIRD-PARTY-NOTICES.md"
Copy-Item "$root/licenses" "$app/licenses" -Recurse -Force
if (!(Test-Path "$app/Murmur.exe") -or !(Test-Path "$app/Cleanup/Murmur.Cleanup.exe")) { throw 'Package is incomplete.' }
# Whisper's NuGet content includes every OS. Keep only this package's x64 DLLs.
Get-ChildItem "$app/runtimes" -Directory | Where-Object { $_.Name -notin @('win-x64', 'noavx') } | Remove-Item -Recurse -Force
Get-ChildItem "$app/runtimes/noavx" -Directory | Where-Object { $_.Name -ne 'win-x64' } | Remove-Item -Recurse -Force
Remove-Item "$app/ggml-metal.metal" -ErrorAction SilentlyContinue
Compress-Archive -Path "$app/*" -DestinationPath "$Output/Murmur-Windows-0.1.0-x64.zip" -Force
if ($Installer) {
    # Bundle Microsoft's signed redistributable for PCs without the native runtime.
    $redist = Join-Path $Output 'VC_redist.x64.exe'
    Invoke-WebRequest 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $redist
    $signature = Get-AuthenticodeSignature $redist
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'The Microsoft runtime signature could not be verified.' }
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if (!$compiler) { $compiler = Get-Item "${env:ProgramFiles(x86)}/Inno Setup 6/ISCC.exe" -ErrorAction Stop }
    $compilerPath = if ($compiler -is [System.Management.Automation.ApplicationInfo]) { $compiler.Source } else { $compiler.FullName }
    & $compilerPath "/DAppSource=$app" "/DOutput=$Output" "/DRedist=$redist" "$PSScriptRoot/installer.iss"
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
}
Get-ChildItem $Output -File | Where-Object { $_.Name -like 'Murmur-Windows-*' } | ForEach-Object {
    $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $($_.Name)" | Set-Content "$($_.FullName).sha256" -Encoding ascii
}
