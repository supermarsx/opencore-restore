#!/bin/sh

# ==============================================================================
# OpenCore Bootloader Restoration Script
# ==============================================================================
#
# Description:
#   Automated EFI bootloader restoration tool designed for macOS Recovery.
#   This script detects EFI partitions, backs up existing configurations,
#   and restores the OpenCore bootloader from the repository.
#
# Usage:
#   ./restore.sh
#
# Requirements:
#   - macOS Recovery environment (or macOS with SIP disabled/appropriate permissions)
#   - 'diskutil' command available
#   - 'nvram' command available
#   - Repository structure with BOOTEFIX64/EFI present
#
# Author: supermarsx
# Repository: https://github.com/supermarsx/opencore-restore
# License: MIT
#
# ==============================================================================

# --- Configuration ---
# Path to the source EFI folder within the repository
REPO_EFI_PATH="./BOOTEFIX64/EFI"

# Directory where backups of the existing EFI will be stored
# Uses a timestamp to ensure uniqueness
BACKUP_DIR="/Volumes/EFI_BACKUP_$(date +%Y%m%d_%H%M%S)"

# --- Colors & Formatting ---
# ANSI escape codes for colored output.
# Note: In some sh environments \033 might not work with echo, using printf is safer.
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
BLUE=$(printf '\033[0;34m')
YELLOW=$(printf '\033[1;33m')
CYAN=$(printf '\033[0;36m')
NC=$(printf '\033[0m') # No Color

# --- Logging Functions ---
# Helper functions to print standardized status messages.

# log_info: Prints an informational message in blue.
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }

# log_success: Prints a success message in green.
log_success() { printf "${GREEN}[ OK ]${NC} %s\n" "$1"; }

# log_warn: Prints a warning message in yellow.
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }

# log_error: Prints an error message in red.
log_error() { printf "${RED}[FAIL]${NC} %s\n" "$1"; }

# header: Clears the screen and prints the script banner.
header() {
    clear
    printf "${CYAN}======================================================${NC}\n"
    printf "${CYAN}       OpenCore Bootloader Restoration Assistant      ${NC}\n"
    printf "${CYAN}======================================================${NC}\n"
    printf "\n"
}

# --- Main Logic ---

header

# 1. Check for Source Files
# Verify that the script is being run from the correct location and the source files exist.
if [ ! -d "$REPO_EFI_PATH" ]; then
    log_error "Could not find source EFI folder at: $REPO_EFI_PATH"
    log_warn "Please ensure you are running this script from the root of the repository."
    exit 1
fi
log_success "Found source EFI files."

# 2. Detect EFI Partition
log_info "Scanning for EFI partitions..."

# Get list of EFI partitions using diskutil.
# Filters for "EFI" type, excludes "Container" (APFS containers), and prints the identifier (last column).
# We use set -- to load them into positional parameters for POSIX sh compatibility (no arrays).
EFI_LIST=$(diskutil list | grep "EFI" | grep -v "Container" | awk '{print $NF}')

if [ -z "$EFI_LIST" ]; then
    log_error "No EFI partitions found!"
    exit 1
fi

# Load the list into positional parameters ($1, $2, etc.)
set -- $EFI_LIST
COUNT=$#

TARGET_DISK=""

if [ "$COUNT" -eq 1 ]; then
    # If only one EFI partition is found, select it automatically.
    TARGET_DISK=$1
    log_info "Found single EFI partition: ${YELLOW}$TARGET_DISK${NC}"
else
    # If multiple partitions are found, prompt the user to select one.
    log_info "Found multiple EFI partitions:"
    i=0
    for disk in "$@"; do
        # Try to get device node info for better context (e.g., disk0s1)
        # Note: diskutil info might fail in minimal sh environments, but usually present in Recovery.
        NODE_INFO=$(diskutil info "$disk" | grep "Device Node" | awk '{print $3}')
        printf "  [%d] ${YELLOW}%s${NC} (%s)\n" "$i" "$disk" "$NODE_INFO"
        i=$((i + 1))
    done

    printf "\n"
    printf "Select partition number [0-$((COUNT - 1))]: "
    read -r SELECTION

    # Validate selection is a number
    case "$SELECTION" in
        '' | *[!0-9]*)
            log_error "Invalid selection."
            exit 1
            ;;
    esac

    if [ "$SELECTION" -ge "$COUNT" ]; then
        log_error "Invalid selection."
        exit 1
    fi

    # Retrieve selection by iterating through the parameters
    i=0
    for disk in "$@"; do
        if [ "$i" -eq "$SELECTION" ]; then
            TARGET_DISK=$disk
            break
        fi
        i=$((i + 1))
    done
fi

# 3. Confirm Action
# Warn the user before making changes to the disk.
printf "\n"
log_warn "You are about to modify the EFI on: ${RED}$TARGET_DISK${NC}"
printf "Are you sure? (y/N): "
read -r CONFIRM
case "$CONFIRM" in
    [yY]*) ;;
    *)
        log_info "Operation cancelled."
        exit 0
        ;;
esac

# 4. Mount EFI
# Mount the selected EFI partition to access its contents.
log_info "Mounting $TARGET_DISK..."
diskutil mount "$TARGET_DISK" >/dev/null
if [ $? -ne 0 ]; then
    log_error "Failed to mount $TARGET_DISK"
    exit 1
fi

EFI_MOUNT_POINT="/Volumes/EFI"
# Check if it mounted to a different number (e.g. /Volumes/EFI 1) if /Volumes/EFI is occupied.
if [ ! -d "$EFI_MOUNT_POINT" ]; then
    # Try to find where it mounted by parsing the 'mount' command output.
    # We use ' \(' as separator to handle the mount options part safely
    EFI_MOUNT_POINT=$(mount | grep "$TARGET_DISK" | awk -F ' on ' '{print $2}' | awk -F ' \\(' '{print $1}')
fi

log_success "Mounted at: $EFI_MOUNT_POINT"

# 5. Backup Existing EFI
# Create a full backup of the current EFI folder before making changes.
if [ -d "$EFI_MOUNT_POINT/EFI" ]; then
    log_info "Backing up existing EFI to $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    cp -R "$EFI_MOUNT_POINT/EFI" "$BACKUP_DIR/"
    if [ $? -eq 0 ]; then
        log_success "Backup created successfully."
    else
        log_warn "Backup failed or completed with errors."
    fi
else
    log_info "No existing EFI folder found. Skipping backup."
fi

# 6. Restore EFI
# Restore the OpenCore bootloader files.
log_info "Restoring OpenCore EFI..."

# Ensure EFI directory exists on the target partition
mkdir -p "$EFI_MOUNT_POINT/EFI"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Rename existing BOOT folder if it exists to preserve it (non-destructive update)
if [ -d "$EFI_MOUNT_POINT/EFI/BOOT" ]; then
    log_info "Renaming existing BOOT to BOOT_OLD_$TIMESTAMP..."
    mv "$EFI_MOUNT_POINT/EFI/BOOT" "$EFI_MOUNT_POINT/EFI/BOOT_OLD_$TIMESTAMP"
fi

# Rename existing OC folder if it exists
if [ -d "$EFI_MOUNT_POINT/EFI/OC" ]; then
    log_info "Renaming existing OC to OC_OLD_$TIMESTAMP..."
    mv "$EFI_MOUNT_POINT/EFI/OC" "$EFI_MOUNT_POINT/EFI/OC_OLD_$TIMESTAMP"
fi

# Copy new folders from the repository
log_info "Copying new BOOT and OC folders..."
cp -R "$REPO_EFI_PATH/BOOT" "$EFI_MOUNT_POINT/EFI/"
cp -R "$REPO_EFI_PATH/OC" "$EFI_MOUNT_POINT/EFI/"

if [ $? -eq 0 ]; then
    log_success "EFI folders restored successfully!"
else
    log_error "Failed to copy EFI files."
    exit 1
fi

# 7. Final Steps
# Clear NVRAM and shutdown to ensure the new bootloader is picked up by the firmware.
printf "\n"
printf "${CYAN}======================================================${NC}\n"
printf "${GREEN}               Restoration Complete!                  ${NC}\n"
printf "${CYAN}======================================================${NC}\n"
printf "\n"
log_warn "IMPORTANT: We need to clear NVRAM to ensure the new boot entry is found."
printf "The system will now clear NVRAM and SHUT DOWN.\n"
printf "Please perform a COLD BOOT (Power button) after shutdown.\n"
printf "\n"
printf "Press Enter to clear NVRAM and Shutdown..."
read -r DUMMY
: "$DUMMY"

log_info "Clearing NVRAM..."
nvram -c

log_info "Shutting down..."
shutdown -h now
