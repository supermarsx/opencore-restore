#!/bin/sh

# ==============================================================================
# OpenCore USB Creator Script
# ==============================================================================
#
# Description:
#   Creates a bootable OpenCore USB drive.
#   Formats the selected drive as GPT/FAT32 and installs the EFI bootloader.
#   This USB can be used to boot macOS, Windows, and Linux via OpenCore.
#
# Usage:
#   ./create_usb.sh
#
# Requirements:
#   - macOS environment
#   - 'diskutil' command available
#   - Repository structure with BOOTEFIX64/EFI present
#
# Warning:
#   THIS SCRIPT WILL ERASE ALL DATA ON THE SELECTED TARGET DRIVE.
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
if [ ! -d "$REPO_EFI_PATH" ]; then
    log_error "EFI source not found at $REPO_EFI_PATH"
    exit 1
fi

# Check for required tools
for cmd in diskutil cp mkdir sync; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Command '$cmd' not found. This script requires macOS and standard system tools."
        exit 1
    fi
done

# --- Main ---

echo "=========================================="
echo "      OpenCore USB Creator"
echo "=========================================="
echo "This script will format a USB drive and install OpenCore."
echo "${RED}WARNING: ALL DATA ON THE TARGET DRIVE WILL BE LOST!${NC}"
echo ""

# List external drives
log_info "Scanning for external drives..."
diskutil list external

echo ""
printf "Enter the disk identifier of the USB drive to format (e.g., disk2): "
read -r TARGET_DISK

if [ -z "$TARGET_DISK" ]; then
    log_error "No disk selected."
    exit 1
fi

# Validate input (basic check to ensure it looks like a disk identifier)
case "$TARGET_DISK" in
    disk*) ;;
    *)
        log_error "Invalid disk identifier. It should start with 'disk' (e.g., disk2)."
        exit 1
        ;;
esac

# Safety check: Try to avoid formatting the internal boot disk (disk0 usually)
if [ "$TARGET_DISK" = "disk0" ]; then
    log_warn "You selected disk0, which is usually the system drive."
    printf "Are you ABSOLUTELY sure? (type 'YES' to proceed): "
    read -r CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        log_info "Aborted."
        exit 0
    fi
fi

# Confirm action
echo ""
log_warn "About to erase /dev/$TARGET_DISK and create a bootable OpenCore drive."
printf "Type 'ERASE' to confirm: "
read -r CONFIRM_ERASE

if [ "$CONFIRM_ERASE" != "ERASE" ]; then
    log_info "Aborted."
    exit 0
fi

# Format
log_info "Formatting /dev/$TARGET_DISK..."
if diskutil eraseDisk FAT32 "$USB_LABEL" GPT "/dev/$TARGET_DISK"; then
    log_success "Drive formatted successfully."
else
    log_error "Failed to format drive."
    exit 1
fi

# Mount (diskutil eraseDisk usually mounts it, but let's be sure where it is)
# The volume should be mounted at /Volumes/OPENCORE
DEST_DIR="/Volumes/$USB_LABEL"

if [ ! -d "$DEST_DIR" ]; then
    log_info "Waiting for volume to mount..."
    sleep 2
    # Try to mount explicitly if not found (though eraseDisk handles this)
    # We need to find the partition identifier, usually slice 1 or 2 depending on EFI
    # For a data partition formatted as FAT32, it's likely the main volume.
    # diskutil eraseDisk FAT32 creates the volume.
fi

if [ ! -d "$DEST_DIR" ]; then
    log_error "Target volume $DEST_DIR not found after formatting."
    exit 1
fi

# Copy EFI
log_info "Copying EFI folder to USB..."
mkdir -p "$DEST_DIR/EFI"
if cp -R "$REPO_EFI_PATH/" "$DEST_DIR/EFI/"; then
    log_success "EFI folder copied successfully."
else
    log_error "Failed to copy EFI folder."
    exit 1
fi

# Sync
log_info "Syncing..."
sync

log_success "Done! OpenCore USB created at $DEST_DIR"
log_info "You can now boot macOS, Windows, or Linux from this drive."
