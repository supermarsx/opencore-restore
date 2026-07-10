<#
.SYNOPSIS
    Interactively creates a verified OpenCore rescue USB on Windows.
.DESCRIPTION
    Erases a selected disk, creates a 1 GiB GPT/FAT32 partition, and copies a
    complete, hardware-specific EFI folder to the root of the USB.
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost',
    '',
    Justification = 'This is an interactive, color-coded disk utility.'
)]
param(
    [string]$EfiSource
)

$ErrorActionPreference = 'Stop'
$BundledEfi = Join-Path $PSScriptRoot 'BOOTEFIX64\EFI'
$UsbLabel = 'OPENCORE'
$CurrentStage = 'initialization'
$driveRoot = $null

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[FAIL] $Message" -ForegroundColor Red }

trap {
    Write-Fail "Failed during $CurrentStage`: $($_.Exception.Message)"
    exit 1
}

function Resolve-EfiFolder {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $Path = $Path.Trim().Trim('"').Trim("'")
    if (Test-Path -LiteralPath (Join-Path $Path 'EFI') -PathType Container) {
        $Path = Join-Path $Path 'EFI'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Test-EfiFolder {
    param(
        [string]$Path,
        [switch]$Quiet
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        if (-not $Quiet) { Write-Fail "EFI folder not found: $Path" }
        return $false
    }

    $required = @('BOOT\BOOTx64.efi', 'OC\OpenCore.efi', 'OC\config.plist')
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Path $_) -PathType Leaf) })
    if ($missing.Count -gt 0) {
        if (-not $Quiet) { Write-Fail "Incomplete EFI folder. Missing: $($missing -join ', ')" }
        return $false
    }

    try {
        [xml](Get-Content -LiteralPath (Join-Path $Path 'OC\config.plist') -Raw) | Out-Null
    }
    catch {
        if (-not $Quiet) { Write-Fail 'OC\config.plist is not valid XML.' }
        return $false
    }
    return $true
}

function Get-EfiManifest {
    param([string]$Path)

    $root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    return @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | ForEach-Object {
        [pscustomobject]@{
            RelativePath = $_.FullName.Substring($root.Length).TrimStart('\')
            Length       = $_.Length
            Hash         = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    } | Sort-Object RelativePath)
}

function Get-DiskIdentity {
    param($Disk)

    return @(
        $Disk.Number,
        $Disk.UniqueId,
        $Disk.SerialNumber,
        $Disk.FriendlyName,
        $Disk.Size,
        $Disk.BusType
    ) -join '|'
}

function Select-EfiFolder {
    param([string]$InitialPath)

    $bundledIsValid = Test-EfiFolder -Path $BundledEfi -Quiet
    if (-not $bundledIsValid) {
        Write-Warn 'The bundled EFI is incomplete and cannot boot by itself.'
    }
    Write-Host 'OpenCore needs a hardware-specific config.plist, drivers, and kexts.'

    $candidate = $InitialPath
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            if ($bundledIsValid) {
                $candidate = Read-Host 'Press Enter for the bundled EFI, or drag another EFI folder here'
                if ([string]::IsNullOrWhiteSpace($candidate)) { $candidate = $BundledEfi }
            }
            else {
                $candidate = Read-Host 'Drag a known-good EFI folder here, enter its path, or type q to quit'
            }
        }
        if ($candidate -eq 'q') { return $null }

        $resolved = Resolve-EfiFolder -Path $candidate
        if (Test-EfiFolder -Path $resolved) { return $resolved }
        $candidate = $null
    }
}

if ($env:OPENCORE_LIBRARY_ONLY -eq '1') {
    return
}

Write-Host '=========================================='
Write-Host '      OpenCore USB Creator (Windows)'
Write-Host '=========================================='
Write-Host 'WARNING: the selected disk will be erased.' -ForegroundColor Red

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail 'Administrator privileges are required.'
    Write-Host 'Open PowerShell as Administrator, change to this folder, and run .\create_usb.ps1'
    exit 1
}

$EfiSource = Select-EfiFolder -InitialPath $EfiSource
if ($null -eq $EfiSource) {
    Write-Info 'Cancelled; no changes were made.'
    exit 0
}
Write-Success "Using EFI source: $EfiSource"
$CurrentStage = 'EFI source inspection'
$sourceManifest = Get-EfiManifest -Path $EfiSource
if ($sourceManifest.Count -eq 0) {
    Write-Fail 'The selected EFI folder contains no files.'
    exit 1
}

$sourceBytes = ($sourceManifest | Measure-Object -Property Length -Sum).Sum

Write-Info 'Scanning for USB and removable disks...'
$candidateDisks = @(Get-Disk | Where-Object {
    -not $_.IsBoot -and -not $_.IsSystem -and ($_.BusType -in @('USB', 'SD', 'MMC'))
})

if ($candidateDisks.Count -eq 0) {
    Write-Warn 'No disk reported itself as USB, SD, or MMC.'
    $showOthers = Read-Host 'List other non-system disks? Type YES to continue'
    if ($showOthers -ne 'YES') {
        Write-Info 'Cancelled; no changes were made.'
        exit 0
    }
    $candidateDisks = @(Get-Disk | Where-Object { -not $_.IsBoot -and -not $_.IsSystem })
}

if ($candidateDisks.Count -eq 0) {
    Write-Fail 'No eligible target disks were found.'
    exit 1
}

$candidateDisks | Sort-Object Number | Format-Table Number, FriendlyName, BusType,
    @{Label = 'Size (GB)'; Expression = { [math]::Round($_.Size / 1GB, 2) }}, PartitionStyle -AutoSize

$diskNumberText = Read-Host 'Enter the disk number to erase, or q to quit'
if ($diskNumberText -eq 'q') { exit 0 }
$diskNumber = 0
if (-not [int]::TryParse($diskNumberText, [ref]$diskNumber)) {
    Write-Fail 'The disk number must be an integer.'
    exit 1
}

$targetDisk = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue
if ($null -eq $targetDisk) {
    Write-Fail "Disk $diskNumber was not found."
    exit 1
}
if ($targetDisk.IsBoot -or $targetDisk.IsSystem) {
    Write-Fail 'Refusing to erase a boot or system disk.'
    exit 1
}
if ($targetDisk.Number -notin $candidateDisks.Number) {
    Write-Fail 'That disk was not in the displayed eligible-disk list.'
    exit 1
}
if ($targetDisk.Size -lt 64MB) {
    Write-Fail 'The selected disk is too small.'
    exit 1
}
$targetIdentity = Get-DiskIdentity -Disk $targetDisk
$plannedPartitionSize = [long][math]::Min([long]1GB, [long]$targetDisk.Size - 16MB)
if ($sourceBytes + 16MB -ge $plannedPartitionSize) {
    Write-Fail "The EFI source needs $sourceBytes bytes and will not fit in the planned $plannedPartitionSize-byte boot partition."
    exit 1
}

$sourceDrive = [System.IO.Path]::GetPathRoot($EfiSource).TrimEnd('\').TrimEnd(':')
if ($sourceDrive.Length -eq 1) {
    $sourcePartition = Get-Partition -DriveLetter $sourceDrive -ErrorAction SilentlyContinue
    if ($null -ne $sourcePartition -and $sourcePartition.DiskNumber -eq $diskNumber) {
        Write-Fail 'The EFI source is stored on the disk selected for erasure. Move it elsewhere first.'
        exit 1
    }
}

Write-Host ''
Write-Host "Target: Disk $diskNumber"
Write-Host "Model:  $($targetDisk.FriendlyName)"
Write-Host "Bus:    $($targetDisk.BusType)"
Write-Host "Size:   $([math]::Round($targetDisk.Size / 1GB, 2)) GB"
Write-Warn "Everything on Disk $diskNumber will be permanently erased."
if ($targetDisk.BusType -notin @('USB', 'SD', 'MMC')) {
    Write-Warn 'This disk is not reported as removable. Check the number and model carefully.'
}
$confirmation = Read-Host "Type ERASE-$diskNumber to continue"
if ($confirmation -ne "ERASE-$diskNumber") {
    Write-Info 'Cancelled; no changes were made.'
    exit 0
}

$CurrentStage = 'final target verification'
$currentSourceManifest = Get-EfiManifest -Path $EfiSource
if (@(Compare-Object -ReferenceObject $sourceManifest -DifferenceObject $currentSourceManifest -Property RelativePath, Length, Hash).Count -gt 0) {
    Write-Fail 'The EFI source changed after it was selected. No erase was attempted.'
    exit 1
}
$verifiedDisk = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue
if ($null -eq $verifiedDisk -or (Get-DiskIdentity -Disk $verifiedDisk) -ne $targetIdentity) {
    Write-Fail 'The selected disk changed or disappeared after confirmation. No erase was attempted.'
    exit 1
}
if ($verifiedDisk.IsBoot -or $verifiedDisk.IsSystem) {
    Write-Fail 'The disk is now reported as a boot or system disk. No erase was attempted.'
    exit 1
}
$targetDisk = $verifiedDisk

try {
    $CurrentStage = 'bringing the target disk online'
    if ($targetDisk.IsOffline) { Set-Disk -Number $diskNumber -IsOffline $false }
    if ($targetDisk.IsReadOnly) { Set-Disk -Number $diskNumber -IsReadOnly $false }

    $CurrentStage = 'disk erasure'
    Write-Info "Cleaning Disk $diskNumber..."
    if ($targetDisk.PartitionStyle -ne 'RAW') {
        Clear-Disk -Number $diskNumber -RemoveData -RemoveOEM -Confirm:$false
    }
    Initialize-Disk -Number $diskNumber -PartitionStyle GPT

    # Windows will not format large volumes as FAT32, so use a small universal boot partition.
    $partitionSize = $plannedPartitionSize
    $CurrentStage = 'EFI System Partition creation'
    Write-Info 'Creating a GPT/FAT32 boot partition...'
    $espType = '{C12A7328-F81F-11D2-BA4B-00A0C93EC93B}'
    $partition = New-Partition -DiskNumber $diskNumber -Size $partitionSize -GptType $espType -AssignDriveLetter
    $null = Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel $UsbLabel -Confirm:$false
    $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber
    if ([string]::IsNullOrWhiteSpace($partition.DriveLetter)) {
        Add-PartitionAccessPath -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber -AssignDriveLetter
        $partition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber
    }
    if ([string]::IsNullOrWhiteSpace($partition.DriveLetter)) {
        throw 'Windows did not assign a drive letter to the new EFI System Partition.'
    }
    $driveRoot = "$($partition.DriveLetter):\"

    $createdDisk = Get-Disk -Number $diskNumber
    $createdPartition = Get-Partition -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber
    $createdVolume = Get-Volume -DriveLetter $partition.DriveLetter
    if ($createdDisk.PartitionStyle -ne 'GPT' -or $createdPartition.GptType -ne $espType) {
        throw 'Partition verification failed: the target is not a GPT EFI System Partition.'
    }
    if ($createdVolume.FileSystem -ne 'FAT32') {
        throw "Filesystem verification failed: expected FAT32, found $($createdVolume.FileSystem)."
    }
    if ($createdVolume.SizeRemaining -le $sourceBytes + 1MB) {
        throw "The EFI source needs $sourceBytes bytes, but only $($createdVolume.SizeRemaining) bytes are free."
    }

    $CurrentStage = 'EFI copy'
    Write-Info "Copying EFI to $driveRoot..."
    Copy-Item -LiteralPath $EfiSource -Destination $driveRoot -Recurse -Force
    $destinationEfi = Join-Path $driveRoot 'EFI'
    if (-not (Test-EfiFolder -Path $destinationEfi)) {
        throw 'Post-copy verification failed. Do not use this USB.'
    }
    $destinationManifest = Get-EfiManifest -Path $destinationEfi
    $manifestDifference = @(Compare-Object -ReferenceObject $sourceManifest -DifferenceObject $destinationManifest -Property RelativePath, Length, Hash)
    if ($manifestDifference.Count -gt 0) {
        throw 'Full-tree copy verification failed. Do not use this USB.'
    }

    $CurrentStage = 'safe removal'
    Write-Success "Verified OpenCore USB at $driveRoot"
    $eject = Read-Host 'Safely remove it now? [Y/n]'
    if ($eject -notmatch '^[nN]') {
        & mountvol $driveRoot /p | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success 'USB safely removed.'
        }
        else {
            Write-Warn 'Automatic removal failed. Use Safely Remove Hardware before unplugging it.'
        }
    }
}
catch {
    Write-Fail "Failed during $CurrentStage`: $($_.Exception.Message)"
    if (-not [string]::IsNullOrWhiteSpace($driveRoot) -and (Test-Path -LiteralPath $driveRoot)) {
        & mountvol $driveRoot /p | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "The incomplete USB remains mounted at $driveRoot. Safely remove it before unplugging."
        }
    }
    exit 1
}
