<#
.SYNOPSIS
    Creates a bootable OpenCore USB drive on Windows.

.DESCRIPTION
    This script formats a selected USB drive as GPT/FAT32 and copies the OpenCore EFI files.
    Requires Administrator privileges.

.NOTES
    File Name      : create_usb.ps1
    Author         : supermarsx
    Prerequisite   : PowerShell 5.1 or later
#>

param()

# --- Configuration ---
$RepoEfiPath = Join-Path $PSScriptRoot "BOOTEFIX64\EFI"
$UsbLabel = "OPENCORE"

# --- Helper Functions ---
function Write-Info { param([string]$msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success { param([string]$msg) Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Error { param([string]$msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

# --- Main Execution ---

Write-Host "=========================================="
Write-Host "      OpenCore USB Creator (Windows)"
Write-Host "=========================================="
Write-Host "This script will format a USB drive and install OpenCore."
Write-Host "WARNING: ALL DATA ON THE TARGET DRIVE WILL BE LOST!" -ForegroundColor Red
Write-Host ""

# 1. Check Administrator Privileges
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "This script requires Administrator privileges."
    Write-Host "Please right-click this script and select 'Run with PowerShell' as Administrator,"
    Write-Host "or run PowerShell as Administrator and execute this script."
    exit 1
}

# 2. Check Source Files
if (-not (Test-Path $RepoEfiPath)) {
    Write-Error "EFI source folder not found at: $RepoEfiPath"
    exit 1
}

# 3. List USB Disks
Write-Info "Scanning for USB drives..."
$usbDisks = Get-Disk | Where-Object { $_.BusType -eq 'USB' }

if ($null -eq $usbDisks -or $usbDisks.Count -eq 0) {
    Write-Warn "No USB drives detected."
    Write-Host "If your drive is not showing up, ensure it is plugged in."
    # Fallback: Allow listing all disks if user insists, but warn heavily
    $showAll = Read-Host "Do you want to list ALL disks (including internal)? (y/n)"
    if ($showAll -eq 'y') {
        $usbDisks = Get-Disk
    } else {
        exit 0
    }
}

$usbDisks | Format-Table -Property Number, FriendlyName, Size, TotalSize, PartitionStyle

Write-Host ""
$diskNumber = Read-Host "Enter the Disk Number of the USB drive to format (e.g., 1)"

if ([string]::IsNullOrWhiteSpace($diskNumber)) {
    Write-Error "No disk selected."
    exit 1
}

# 4. Validate Selection
$targetDisk = Get-Disk -Number $diskNumber -ErrorAction SilentlyContinue

if ($null -eq $targetDisk) {
    Write-Error "Disk $diskNumber not found."
    exit 1
}

# Safety Check: Boot Drive
if ($targetDisk.IsBoot) {
    Write-Error "Disk $diskNumber appears to be the boot drive. Aborting for safety."
    exit 1
}

# Safety Check: Non-USB
if ($targetDisk.BusType -ne 'USB') {
    Write-Warn "Disk $diskNumber is NOT detected as a USB drive (BusType: $($targetDisk.BusType))."
    $confirmNonUsb = Read-Host "Are you ABSOLUTELY sure you want to erase this disk? (Type 'YES')"
    if ($confirmNonUsb -ne 'YES') {
        Write-Info "Aborted."
        exit 0
    }
}

# 5. Confirm Erase
Write-Host ""
Write-Warn "About to ERASE ALL DATA on Disk $diskNumber ($($targetDisk.FriendlyName))."
$confirmErase = Read-Host "Type 'ERASE' to confirm"

if ($confirmErase -ne 'ERASE') {
    Write-Info "Aborted."
    exit 0
}

# 6. Perform Disk Operations
try {
    Write-Info "Cleaning disk $diskNumber..."
    Clear-Disk -Number $diskNumber -RemoveData -Confirm:$false -ErrorAction Stop

    Write-Info "Initializing disk as GPT..."
    Initialize-Disk -Number $diskNumber -PartitionStyle GPT -ErrorAction Stop

    Write-Info "Creating partition..."
    $partition = New-Partition -DiskNumber $diskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    
    # Wait a moment for the volume to be ready
    Start-Sleep -Seconds 2

    Write-Info "Formatting partition as FAT32..."
    Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel $UsbLabel -Confirm:$false -ErrorAction Stop

    $driveLetter = "$($partition.DriveLetter):"
    Write-Success "Drive formatted and mounted at $driveLetter"

    # 7. Copy Files
    $destEfiPath = Join-Path $driveLetter "EFI"
    
    Write-Info "Copying EFI folder to $driveLetter..."
    Copy-Item -Path $RepoEfiPath -Destination $destEfiPath -Recurse -Force -ErrorAction Stop

    Write-Success "Done! OpenCore USB created successfully."
    Write-Info "You can now boot from this USB drive."

} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    exit 1
}
