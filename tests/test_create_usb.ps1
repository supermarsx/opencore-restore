$ErrorActionPreference = 'Stop'
$env:OPENCORE_LIBRARY_ONLY = '1'
. (Join-Path $PSScriptRoot '..\create_usb.ps1')

$testRoot = Join-Path $PSScriptRoot 'test_windows_usb'
$efi = Join-Path $testRoot 'EFI'
$failures = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "[PASS] $Message"
    }
    else {
        Write-Host "[FAIL] $Message"
        $script:failures++
    }
}

try {
    New-Item -ItemType Directory -Force -Path (Join-Path $efi 'BOOT'), (Join-Path $efi 'OC') | Out-Null
    Set-Content -LiteralPath (Join-Path $efi 'BOOT\BOOTx64.efi') -Value 'boot'
    Set-Content -LiteralPath (Join-Path $efi 'OC\OpenCore.efi') -Value 'oc'
    Set-Content -LiteralPath (Join-Path $efi 'OC\config.plist') -Value '<plist version="1.0"><dict/></plist>'

    Assert-True (Test-EfiFolder -Path $efi -Quiet) 'complete EFI passes validation'
    Assert-True ((Resolve-EfiFolder -Path $testRoot) -eq (Resolve-Path $efi).Path) 'parent path resolves to its EFI folder'

    $manifestBefore = Get-EfiManifest -Path $efi
    Add-Content -LiteralPath (Join-Path $efi 'OC\OpenCore.efi') -Value 'changed'
    $manifestAfter = Get-EfiManifest -Path $efi
    $difference = @(Compare-Object $manifestBefore $manifestAfter -Property RelativePath, Length, Hash)
    Assert-True ($difference.Count -gt 0) 'manifest detects a changed EFI file'

    Remove-Item -LiteralPath (Join-Path $efi 'OC\config.plist')
    Assert-True (-not (Test-EfiFolder -Path $efi -Quiet)) 'missing config.plist fails validation'

    $diskA = [pscustomobject]@{ Number = 3; UniqueId = 'A'; SerialNumber = 'S'; FriendlyName = 'USB'; Size = 1GB; BusType = 'USB' }
    $diskB = [pscustomobject]@{ Number = 3; UniqueId = 'B'; SerialNumber = 'S'; FriendlyName = 'USB'; Size = 1GB; BusType = 'USB' }
    Assert-True ((Get-DiskIdentity $diskA) -ne (Get-DiskIdentity $diskB)) 'disk identity detects device replacement'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCORE_LIBRARY_ONLY -ErrorAction SilentlyContinue
}

if ($failures -gt 0) {
    throw "$failures PowerShell USB test(s) failed."
}
Write-Host 'All PowerShell USB tests passed.'
