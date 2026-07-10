#!/bin/sh

# Create a GPT/FAT32 OpenCore rescue USB on Linux.

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUNDLED_EFI="$SCRIPT_DIR/BOOTEFIX64/EFI"
USB_LABEL="OPENCORE"
MOUNT_POINT=""
MOUNTED=0
TARGET_DISK=""
COMPLETED=0
DISK_MODIFIED=0

RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
BLUE=$(printf '\033[0;34m')
YELLOW=$(printf '\033[1;33m')
NC=$(printf '\033[0m')

log_info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$1"; }
log_success() { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$1"; }
log_warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1"; }
log_error() { printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$1" >&2; }

die() {
    log_error "$1"
    exit 1
}

cleanup() {
    status=$?
    if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_POINT" ]; then
        sync
        if ! umount "$MOUNT_POINT" >/dev/null 2>&1; then
            log_warn "Could not unmount $MOUNT_POINT; do not unplug the USB yet."
        fi
    fi
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT" ]; then
        rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    if [ "$status" -ne 0 ] && [ "$COMPLETED" -eq 0 ] && [ "$DISK_MODIFIED" -eq 1 ]; then
        log_warn "The operation did not complete. Do not try to boot from this USB."
    fi
}
trap cleanup EXIT
trap 'log_error "Interrupted."; exit 130' INT
trap 'log_error "Terminated."; exit 143' HUP TERM

clean_path() {
    printf '%s' "$1" | sed "s/^['\"]//;s/['\"]$//;s/\\\\ / /g"
}

normalize_efi_path() {
    candidate=$(clean_path "$1")
    [ -d "$candidate/EFI" ] && candidate="$candidate/EFI"
    printf '%s' "$candidate"
}

validate_efi() {
    source_path=$1
    missing=""
    for relative_path in BOOT/BOOTx64.efi OC/OpenCore.efi OC/config.plist; do
        [ -f "$source_path/$relative_path" ] || missing="$missing $relative_path"
    done
    if [ -n "$missing" ]; then
        log_error "That is not a complete OpenCore EFI folder. Missing:$missing"
        return 1
    fi
    if command -v xmllint >/dev/null 2>&1 && ! xmllint --noout "$source_path/OC/config.plist" 2>/dev/null; then
        log_error "The selected OC/config.plist is not valid XML."
        return 1
    fi
    if ! command -v xmllint >/dev/null 2>&1 && ! grep -q '<plist[ >]' "$source_path/OC/config.plist"; then
        log_error "The selected OC/config.plist does not look like an XML property list."
        return 1
    fi
    return 0
}

target_fingerprint() {
    lsblk -dnbo SIZE,MODEL,SERIAL,WWN,TRAN,RM,TYPE "$TARGET_DISK" 2>/dev/null
}

verify_target_identity() {
    current_fingerprint=$(target_fingerprint) || return 1
    [ -n "$current_fingerprint" ] && [ "$current_fingerprint" = "$TARGET_FINGERPRINT" ]
}

verify_copy() {
    validate_efi "$MOUNT_POINT/EFI" && diff -qr "$EFI_SOURCE" "$MOUNT_POINT/EFI" >/dev/null 2>&1
}

choose_efi_source() {
    printf '\nOpenCore needs a hardware-specific config.plist, drivers, and kexts.\n'
    if validate_efi "$BUNDLED_EFI" 2>/dev/null; then
        printf 'Press Enter to use the bundled EFI, or enter another EFI folder path: '
    else
        log_warn "The bundled EFI is incomplete and cannot boot by itself."
        printf 'Enter the path to a known-good EFI folder: '
    fi
    while :; do
        read -r entered_path || exit 1
        [ "$entered_path" = "q" ] && exit 0
        if [ -z "$entered_path" ] && validate_efi "$BUNDLED_EFI" 2>/dev/null; then
            EFI_SOURCE=$BUNDLED_EFI
        else
            EFI_SOURCE=$(normalize_efi_path "$entered_path")
        fi
        if validate_efi "$EFI_SOURCE"; then
            log_success "Using EFI source: $EFI_SOURCE"
            return 0
        fi
        printf 'Enter another EFI folder path, or q to quit: '
    done
}

if [ "$(id -u)" -ne 0 ]; then
    log_error "Run this script as root: sudo ./create_usb_linux.sh"
    exit 1
fi

for cmd in lsblk findmnt parted mkfs.vfat mount umount cp mkdir sync sed awk grep du df diff mktemp basename; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        log_error "On Debian/Ubuntu, install util-linux, parted, and dosfstools."
        exit 1
    fi
done

printf '==========================================\n'
printf '      OpenCore USB Creator (Linux)\n'
printf '==========================================\n'
printf '%sWARNING: the selected disk will be erased.%s\n' "$RED" "$NC"

choose_efi_source
SOURCE_KB=$(du -sk "$EFI_SOURCE" | awk '{print $1}')
case "$SOURCE_KB" in
    '' | *[!0-9]*) die "Could not determine the EFI source size." ;;
esac

printf '\n'
log_info "Available removable/USB disks:"
lsblk -dpno NAME,TRAN,RM,SIZE,TYPE | awk '$5 == "disk" && ($2 == "usb" || $3 == "1") {print}'
printf '\nEnter the whole device path (for example /dev/sdb), or q to quit: '
read -r TARGET_DISK
[ "$TARGET_DISK" = "q" ] && exit 0

if [ ! -b "$TARGET_DISK" ] && [ "${OPENCORE_ALLOW_MOCK_DEVICES:-0}" != "1" ]; then
    log_error "Block device not found: $TARGET_DISK"
    exit 1
fi
if [ "$(lsblk -dno TYPE "$TARGET_DISK" 2>/dev/null)" != "disk" ]; then
    log_error "Select a whole disk, not a partition."
    exit 1
fi
TARGET_FINGERPRINT=$(target_fingerprint) || die "Could not read stable identity information for $TARGET_DISK."
[ -n "$TARGET_FINGERPRINT" ] || die "Could not read stable identity information for $TARGET_DISK."
TARGET_BYTES=$(lsblk -dnbo SIZE "$TARGET_DISK" 2>/dev/null | awk '{$1=$1; print}')
case "$TARGET_BYTES" in
    '' | *[!0-9]*) die "Could not determine the target disk size." ;;
esac
if [ "$TARGET_BYTES" -le $(((SOURCE_KB + 4096) * 1024)) ]; then
    die "The selected disk is too small for the EFI source."
fi

TRAN=$(lsblk -dno TRAN "$TARGET_DISK" 2>/dev/null | awk '{$1=$1;print}')
REMOVABLE=$(lsblk -dno RM "$TARGET_DISK" 2>/dev/null | awk '{$1=$1;print}')
if [ "$TRAN" != "usb" ] && [ "$REMOVABLE" != "1" ]; then
    log_error "Refusing a disk that is neither USB nor marked removable."
    exit 1
fi

ROOT_SOURCE=$(findmnt -no SOURCE / 2>/dev/null || true)
ROOT_PARENT=""
if [ -n "$ROOT_SOURCE" ]; then
    ROOT_PARENT=$(lsblk -sno NAME,TYPE "$ROOT_SOURCE" 2>/dev/null | awk '$2 == "disk" {print "/dev/" $1; exit}')
fi
if [ "$TARGET_DISK" = "$ROOT_SOURCE" ] || [ "$TARGET_DISK" = "$ROOT_PARENT" ]; then
    log_error "Refusing to erase the disk containing the running system."
    exit 1
fi

SOURCE_DEVICE=$(findmnt -no SOURCE -T "$EFI_SOURCE" 2>/dev/null || true)
SOURCE_DISK=$(lsblk -sno NAME,TYPE "$SOURCE_DEVICE" 2>/dev/null | awk '$2 == "disk" {print "/dev/" $1; exit}')
if [ -n "$SOURCE_DISK" ] && [ "$TARGET_DISK" = "$SOURCE_DISK" ]; then
    log_error "The EFI source is stored on the disk selected for erasure. Move it elsewhere first."
    exit 1
fi

printf '\n'
lsblk -dno NAME,SIZE,MODEL,TRAN,RM "$TARGET_DISK"
log_warn "Everything on $TARGET_DISK will be permanently erased."
TARGET_NAME=$(basename "$TARGET_DISK")
printf 'Type ERASE-%s to continue: ' "$TARGET_NAME"
read -r CONFIRM_ERASE
if [ "$CONFIRM_ERASE" != "ERASE-$TARGET_NAME" ]; then
    log_info "Cancelled; no changes were made."
    exit 0
fi

verify_target_identity || die "The selected disk changed or disappeared after confirmation. No erase was attempted."

log_info "Unmounting existing partitions..."
if ! lsblk -lnpo NAME,MOUNTPOINT "$TARGET_DISK" | awk 'NF > 1 && $2 != "" {print $1}' |
    while IFS= read -r partition; do
        umount "$partition" || exit 1
    done; then
    log_error "Could not unmount every partition on $TARGET_DISK."
    exit 1
fi

log_info "Creating GPT partition table and FAT32 ESP..."
DISK_MODIFIED=1
parted -s "$TARGET_DISK" mklabel gpt || die "Failed to create a GPT partition table."
parted -s "$TARGET_DISK" mkpart OPENCORE fat32 1MiB 100% || die "Failed to create the FAT32 partition."
parted -s "$TARGET_DISK" set 1 esp on || die "Failed to mark the partition as an EFI System Partition."
command -v partprobe >/dev/null 2>&1 && partprobe "$TARGET_DISK" || true
command -v udevadm >/dev/null 2>&1 && udevadm settle || sleep 2

PARTITION=$(lsblk -lnpo NAME,TYPE "$TARGET_DISK" | awk '$2 == "part" {print $1; exit}')
if [ -z "$PARTITION" ]; then
    log_error "The new partition did not appear. Reconnect the USB and try again."
    exit 1
fi

mkfs.vfat -F 32 -n "$USB_LABEL" "$PARTITION" || die "Failed to format $PARTITION as FAT32."
FSTYPE=$(lsblk -no FSTYPE "$PARTITION" 2>/dev/null | awk '{$1=$1; print}')
[ "$FSTYPE" = "vfat" ] || die "Filesystem verification failed: expected vfat, found ${FSTYPE:-unknown}."
PARTTYPE=$(lsblk -no PARTTYPE "$PARTITION" 2>/dev/null | awk '{$1=$1; print}')
case "$PARTTYPE" in
    c12a7328-f81f-11d2-ba4b-00a0c93ec93b | C12A7328-F81F-11D2-BA4B-00A0C93EC93B) ;;
    *) die "Partition verification failed: $PARTITION is not marked as an EFI System Partition." ;;
esac
MOUNT_POINT=$(mktemp -d /tmp/opencore-usb.XXXXXX) || die "Could not create a temporary mount point."
mount "$PARTITION" "$MOUNT_POINT" || die "Failed to mount $PARTITION."
MOUNTED=1

AVAILABLE_KB=$(df -kP "$MOUNT_POINT" | awk 'NR == 2 {print $4}')
case "$AVAILABLE_KB" in
    '' | *[!0-9]*) die "Could not determine free space on $PARTITION." ;;
esac
if [ "$AVAILABLE_KB" -le $((SOURCE_KB + 1024)) ]; then
    die "The EFI source needs ${SOURCE_KB} KiB, but $PARTITION has only ${AVAILABLE_KB} KiB free."
fi

log_info "Copying EFI to $MOUNT_POINT/EFI..."
mkdir -p "$MOUNT_POINT/EFI" || die "Could not create $MOUNT_POINT/EFI."
cp -R "$EFI_SOURCE"/. "$MOUNT_POINT/EFI/" || die "Failed to copy the EFI files."

sync
verify_copy || die "Post-copy verification failed. Do not use this USB."
umount "$MOUNT_POINT" || die "Copy succeeded, but the USB could not be safely unmounted."
MOUNTED=0
rmdir "$MOUNT_POINT" || die "Could not remove the temporary mount point."
MOUNT_POINT=""
COMPLETED=1
log_success "OpenCore USB created and safely unmounted: $TARGET_DISK"
