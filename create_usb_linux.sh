#!/bin/sh

# ==============================================================================
# OpenCore USB Creator Script (Linux)
# ==============================================================================
#
# Description:
#   Creates a bootable OpenCore USB drive on Linux.
#   Formats the selected drive as GPT/FAT32 and installs the EFI bootloader.
#
# Usage:
#   sudo ./create_usb_linux.sh
#
# Requirements:
#   - Root privileges (sudo)
#   - 'lsblk', 'parted', 'mkfs.vfat' (dosfstools)
#
# ==============================================================================

# --- Configuration ---
REPO_EFI_PATH="./BOOTEFIX64/EFI"
USB_LABEL="OPENCORE"

# --- Colors ---
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
BLUE=$(printf '\033[0;34m')
YELLOW=$(printf '\033[1;33m')
NC=$(printf '\033[0m')

# --- Logging ---
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# --- Checks ---
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root. Try 'sudo ./create_usb_linux.sh'."
    exit 1
fi

if [ ! -d "$REPO_EFI_PATH" ]; then
    log_error "EFI source not found at $REPO_EFI_PATH"
    exit 1
fi

for cmd in lsblk parted mkfs.vfat mount umount cp mkdir sync grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Command '$cmd' not found. Please install required tools (e.g., dosfstools, parted)."
        exit 1
    fi
done

# --- Main ---

echo "=========================================="
echo "      OpenCore USB Creator (Linux)"
echo "=========================================="
echo "This script will format a USB drive and install OpenCore."
echo "${RED}WARNING: ALL DATA ON THE TARGET DRIVE WILL BE LOST!${NC}"
echo ""

# List drives
log_info "Scanning for drives..."
# Try to list only USB drives if possible, otherwise list all removable
lsblk -o NAME,TRAN,SIZE,MODEL,TYPE | grep -E "usb|disk"

echo ""
printf "Enter the device path of the USB drive (e.g., /dev/sdb): "
read -r TARGET_DISK

if [ -z "$TARGET_DISK" ]; then
    log_error "No disk selected."
    exit 1
fi

if [ ! -b "$TARGET_DISK" ]; then
    log_error "Invalid device: $TARGET_DISK"
    exit 1
fi

# Safety check: prevent formatting common system drives like /dev/sda or /dev/nvme0n1 if they look large or system-like?
# Hard to detect reliably in sh without complex logic. We rely on user confirmation.

log_warn "About to ERASE ALL DATA on $TARGET_DISK."
printf "Type 'ERASE' to confirm: "
read -r CONFIRM_ERASE

if [ "$CONFIRM_ERASE" != "ERASE" ]; then
    log_info "Aborted."
    exit 0
fi

# Unmount any existing partitions on the target
log_info "Unmounting existing partitions on $TARGET_DISK..."
for part in "${TARGET_DISK}"*; do
    if mount | grep -q "$part"; then
        umount "$part"
    fi
done

# Partitioning
log_info "Creating GPT partition table on $TARGET_DISK..."
parted -s "$TARGET_DISK" mklabel gpt
if [ $? -ne 0 ]; then
    log_error "Failed to create partition table."
    exit 1
fi

log_info "Creating FAT32 partition..."
parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 100%
if [ $? -ne 0 ]; then
    log_error "Failed to create partition."
    exit 1
fi

log_info "Setting ESP flag..."
parted -s "$TARGET_DISK" set 1 esp on

# Determine partition name
# For /dev/sdb -> /dev/sdb1
# For /dev/nvme0n1 -> /dev/nvme0n1p1
if echo "$TARGET_DISK" | grep -q "nvme"; then
    PARTITION="${TARGET_DISK}p1"
else
    PARTITION="${TARGET_DISK}1"
fi

# Wait for kernel to update partition table
sleep 2

if [ ! -b "$PARTITION" ]; then
    log_error "Partition $PARTITION not found after creation."
    exit 1
fi

# Format
log_info "Formatting $PARTITION as FAT32..."
mkfs.vfat -F 32 -n "$USB_LABEL" "$PARTITION"
if [ $? -ne 0 ]; then
    log_error "Failed to format partition."
    exit 1
fi

# Mount
MOUNT_POINT="/mnt/opencore_usb_$(date +%s)"
mkdir -p "$MOUNT_POINT"

log_info "Mounting $PARTITION to $MOUNT_POINT..."
mount "$PARTITION" "$MOUNT_POINT"
if [ $? -ne 0 ]; then
    log_error "Failed to mount partition."
    exit 1
fi

# Copy
log_info "Copying EFI folder..."
mkdir -p "$MOUNT_POINT/EFI"
cp -R "$REPO_EFI_PATH/" "$MOUNT_POINT/EFI/"
if [ $? -ne 0 ]; then
    log_error "Failed to copy files."
    umount "$MOUNT_POINT"
    exit 1
fi

# Cleanup
log_info "Syncing and unmounting..."
sync
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

log_success "Done! OpenCore USB created on $TARGET_DISK."
