# Run on Windows after signing, before publishing or updating download links.
param(
    [Parameter(Mandatory)][string]$AppDirectory,
    [Parameter(Mandatory)][string]$InstallerPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$ExpectedSignerThumbprint
)
$ErrorActionPreference = 'Stop'
$owned = @('Murmur.exe', 'Murmur.dll', 'Murmur.Core.dll', 'Cleanup/Murmur.Cleanup.exe', 'Cleanup/Murmur.Cleanup.dll')
$files = @($owned | ForEach-Object { Join-Path $AppDirectory $_ }) + @($InstallerPath)
$invalid = @()
foreach ($file in $files) {
    if (!(Test-Path $file -PathType Leaf)) { $invalid += "Missing release file: $file"; continue }
    $signature = Get-AuthenticodeSignature $file
    if ($signature.Status -ne 'Valid' -or
        $signature.SignerCertificate.Thumbprint -ne $ExpectedSignerThumbprint -or
        $null -eq $signature.TimeStamperCertificate) {
        $invalid += "Untrusted, unexpected, or untimestamped signature: $file ($($signature.Status))"
    }
}
if ($invalid.Count) { throw "Windows release signing gate failed:`n$($invalid -join "`n")" }
Write-Host 'All Murmur binaries and the installer have valid, timestamped signatures from the expected publisher.'
