#!/bin/sh

# Create a GPT/FAT32 OpenCore rescue USB on macOS.

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUNDLED_EFI="$SCRIPT_DIR/BOOTEFIX64/EFI"
USB_LABEL="OPENCORE"
TARGET_DISK=""
PARTITION=""
MOUNT_POINT=""
MOUNTED_BY_SCRIPT=0
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
    if [ "$status" -ne 0 ] && [ "$MOUNTED_BY_SCRIPT" -eq 1 ] && [ -n "$PARTITION" ]; then
        if ! diskutil unmount "/dev/$PARTITION" >/dev/null 2>&1; then
            log_warn "Could not unmount /dev/$PARTITION; eject it in Finder before unplugging."
        fi
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
    if [ -d "$candidate/EFI" ]; then
        candidate="$candidate/EFI"
    fi
    printf '%s' "$candidate"
}

validate_efi() {
    source_path=$1
    missing=""
    for relative_path in BOOT/BOOTx64.efi OC/OpenCore.efi OC/config.plist; do
        if [ ! -f "$source_path/$relative_path" ]; then
            missing="$missing $relative_path"
        fi
    done
    if [ -n "$missing" ]; then
        log_error "That is not a complete OpenCore EFI folder. Missing:$missing"
        return 1
    fi
    if ! plutil -lint "$source_path/OC/config.plist" >/dev/null 2>&1; then
        log_error "The selected OC/config.plist is not a valid property list."
        return 1
    fi
    return 0
}

verify_target_identity() {
    current_external=$(diskutil list external physical 2>/dev/null) || return 1
    printf '%s\n' "$current_external" | grep -q "^/dev/$TARGET_DISK " || return 1
    current_info=$(diskutil info "/dev/$TARGET_DISK" 2>/dev/null) || return 1
    current_whole=$(printf '%s\n' "$current_info" | awk -F: '/Whole:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    current_internal=$(printf '%s\n' "$current_info" | awk -F: '/Internal:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
    current_name=$(printf '%s\n' "$current_info" | awk -F: '/Media Name:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
    current_size=$(printf '%s\n' "$current_info" | awk -F: '/Disk Size:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
    [ "$current_whole" = "Yes" ] && [ "$current_internal" != "Yes" ] &&
        [ "$current_name" = "$MEDIA_NAME" ] && [ "$current_size" = "$DISK_SIZE" ]
}

verify_copy() {
    validate_efi "$MOUNT_POINT/EFI" && diff -qr "$EFI_SOURCE" "$MOUNT_POINT/EFI" >/dev/null 2>&1
}

choose_efi_source() {
    printf '\nOpenCore needs a hardware-specific config.plist, drivers, and kexts.\n'
    if validate_efi "$BUNDLED_EFI" 2>/dev/null; then
        printf 'Press Enter to use the bundled EFI, or drag another EFI folder here: '
    else
        log_warn "The bundled EFI is incomplete and cannot boot by itself."
        printf 'Drag a known-good EFI folder here, or enter its path: '
    fi

    while :; do
        read -r entered_path || exit 1
        if [ -z "$entered_path" ] && validate_efi "$BUNDLED_EFI" 2>/dev/null; then
            EFI_SOURCE=$BUNDLED_EFI
        else
            EFI_SOURCE=$(normalize_efi_path "$entered_path")
        fi
        if validate_efi "$EFI_SOURCE"; then
            log_success "Using EFI source: $EFI_SOURCE"
            return 0
        fi
        printf 'Enter another EFI folder path, or type q to quit: '
    done
}

for cmd in diskutil ditto plutil sed awk grep df du diff sync; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

printf '==========================================\n'
printf '      OpenCore USB Creator (macOS)\n'
printf '==========================================\n'
printf '%sWARNING: the selected disk will be erased.%s\n' "$RED" "$NC"

choose_efi_source
SOURCE_KB=$(du -sk "$EFI_SOURCE" | awk '{print $1}')
case "$SOURCE_KB" in
    '' | *[!0-9]*) die "Could not determine the EFI source size." ;;
esac
if [ "$SOURCE_KB" -gt 184320 ]; then
    die "The EFI source is larger than 180 MiB and will not fit in a standard macOS EFI System Partition."
fi

printf '\n'
log_info "External physical disks:"
EXTERNAL_DISKS=$(diskutil list external physical) || {
    log_error "Could not list external disks."
    exit 1
}
printf '%s\n' "$EXTERNAL_DISKS"

printf '\nEnter the whole disk identifier (for example disk2), or q to quit: '
read -r TARGET_DISK
[ "$TARGET_DISK" = "q" ] && exit 0
if ! printf '%s\n' "$TARGET_DISK" | grep -Eq '^disk[0-9]+$'; then
    log_error "Enter a whole disk identifier such as disk2, without /dev/."
    exit 1
fi

DISK_INFO=$(diskutil info "/dev/$TARGET_DISK" 2>/dev/null) || {
    log_error "Disk /dev/$TARGET_DISK was not found."
    exit 1
}
if ! printf '%s\n' "$EXTERNAL_DISKS" | grep -q "^/dev/$TARGET_DISK "; then
    log_error "Refusing a disk that was not in the external physical disk list."
    exit 1
fi
WHOLE=$(printf '%s\n' "$DISK_INFO" | awk -F: '/Whole:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
INTERNAL=$(printf '%s\n' "$DISK_INFO" | awk -F: '/Internal:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
LOCATION=$(printf '%s\n' "$DISK_INFO" | awk -F: '/Device Location:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
MEDIA_NAME=$(printf '%s\n' "$DISK_INFO" | awk -F: '/Media Name:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
DISK_SIZE=$(printf '%s\n' "$DISK_INFO" | awk -F: '/Disk Size:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')

[ -n "$MEDIA_NAME" ] || die "Could not read the target disk model."
[ -n "$DISK_SIZE" ] || die "Could not read the target disk size."

if [ "$WHOLE" != "Yes" ]; then
    log_error "/dev/$TARGET_DISK is not a whole disk."
    exit 1
fi
if [ "$INTERNAL" = "Yes" ] || [ "$LOCATION" = "Internal" ]; then
    log_error "Refusing to erase an internal disk."
    exit 1
fi

SOURCE_DEVICE=$(df "$EFI_SOURCE" | awk 'NR == 2 {print $1}')
case "$SOURCE_DEVICE" in
    "/dev/${TARGET_DISK}" | "/dev/${TARGET_DISK}"s*)
        log_error "The EFI source is stored on the disk selected for erasure. Move it elsewhere first."
        exit 1
        ;;
esac

printf '\nTarget: /dev/%s\n' "$TARGET_DISK"
printf 'Model:  %s\n' "${MEDIA_NAME:-Unknown}"
printf 'Size:   %s\n' "${DISK_SIZE:-Unknown}"
log_warn "Everything on /dev/$TARGET_DISK will be permanently erased."
printf 'Type ERASE-%s to continue: ' "$TARGET_DISK"
read -r CONFIRM_ERASE
if [ "$CONFIRM_ERASE" != "ERASE-$TARGET_DISK" ]; then
    log_info "Cancelled; no changes were made."
    exit 0
fi

if ! verify_target_identity; then
    die "The selected disk changed or disappeared after confirmation. No erase was attempted."
fi

log_info "Creating a GPT disk with an EFI System Partition..."
DISK_MODIFIED=1
if ! diskutil eraseDisk FAT32 "$USB_LABEL" GPT "/dev/$TARGET_DISK"; then
    log_error "Disk formatting failed."
    exit 1
fi

PARTITION=$(diskutil list "/dev/$TARGET_DISK" | awk '$2 == "EFI" || $3 == "EFI" {print $NF; exit}')
if [ -z "$PARTITION" ]; then
    log_error "Could not identify the new EFI System Partition."
    exit 1
fi

MOUNT_POINT=$(diskutil info "/dev/$PARTITION" | awk -F: '/Mount Point:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
if [ -z "$MOUNT_POINT" ] || [ "$MOUNT_POINT" = "Not mounted" ]; then
    diskutil mount "/dev/$PARTITION" >/dev/null || die "Failed to mount /dev/$PARTITION."
    MOUNTED_BY_SCRIPT=1
    MOUNT_POINT=$(diskutil info "/dev/$PARTITION" | awk -F: '/Mount Point:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
fi
if [ ! -d "$MOUNT_POINT" ]; then
    log_error "The new volume did not mount correctly."
    exit 1
fi
MOUNTED_BY_SCRIPT=1

AVAILABLE_KB=$(df -kP "$MOUNT_POINT" | awk 'NR == 2 {print $4}')
case "$AVAILABLE_KB" in
    '' | *[!0-9]*) die "Could not determine free space on the EFI System Partition." ;;
esac
if [ "$AVAILABLE_KB" -le $((SOURCE_KB + 1024)) ]; then
    die "The EFI source needs ${SOURCE_KB} KiB, but the EFI System Partition has only ${AVAILABLE_KB} KiB free."
fi

log_info "Copying EFI to $MOUNT_POINT/EFI..."
if ! ditto "$EFI_SOURCE" "$MOUNT_POINT/EFI"; then
    log_error "Copy failed. The USB was formatted but is not ready to boot."
    exit 1
fi
sync
verify_copy || die "Post-copy verification failed. Do not use this USB."

COMPLETED=1
log_success "Verified OpenCore USB at $MOUNT_POINT."
printf 'Eject it now? [Y/n]: '
read -r EJECT_CHOICE
case "$EJECT_CHOICE" in
    [nN]*) log_info "Leave it mounted only until all writes are complete." ;;
    *)
        if diskutil eject "/dev/$TARGET_DISK" >/dev/null; then
            MOUNTED_BY_SCRIPT=0
            log_success "USB safely ejected."
        else
            log_warn "Automatic eject failed; eject it in Finder before unplugging."
        fi
        ;;
esac
