#!/bin/sh

# Safely restore a complete OpenCore EFI from macOS or macOS Recovery.

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUNDLED_EFI="$SCRIPT_DIR/BOOTEFIX64/EFI"
TARGET_PARTITION=""
EFI_MOUNT_POINT=""
MOUNTED_BY_SCRIPT=0
STAGE_DIR=""
OLD_BOOT=""
OLD_OC=""
OLD_BOOT_MOVED=0
OLD_OC_MOVED=0
NEW_BOOT_MOVED=0
NEW_OC_MOVED=0
INSTALL_COMMITTED=0
ROLLBACK_FAILED=0

RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
BLUE=$(printf '\033[0;34m')
YELLOW=$(printf '\033[1;33m')
CYAN=$(printf '\033[0;36m')
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
    restore_boot=1
    restore_oc=1
    if [ "$INSTALL_COMMITTED" -eq 0 ]; then
        if [ "$NEW_BOOT_MOVED" -eq 1 ] && ! rm -rf "$EFI_MOUNT_POINT/EFI/BOOT"; then
            log_error "Could not remove the partial BOOT installation during rollback."
            ROLLBACK_FAILED=1
            restore_boot=0
        fi
        if [ "$NEW_OC_MOVED" -eq 1 ] && ! rm -rf "$EFI_MOUNT_POINT/EFI/OC"; then
            log_error "Could not remove the partial OC installation during rollback."
            ROLLBACK_FAILED=1
            restore_oc=0
        fi
        if [ "$OLD_BOOT_MOVED" -eq 1 ] && [ -d "$OLD_BOOT" ] && [ "$restore_boot" -eq 1 ]; then
            if [ -e "$EFI_MOUNT_POINT/EFI/BOOT" ]; then
                log_error "Cannot restore the previous BOOT folder because the destination still exists."
                ROLLBACK_FAILED=1
                restore_boot=0
            fi
        fi
        if [ "$OLD_BOOT_MOVED" -eq 1 ] && [ -d "$OLD_BOOT" ] && [ "$restore_boot" -eq 1 ]; then
            if ! mv "$OLD_BOOT" "$EFI_MOUNT_POINT/EFI/BOOT"; then
                log_error "Could not restore the previous BOOT folder from $OLD_BOOT."
                ROLLBACK_FAILED=1
            fi
        fi
        if [ "$OLD_OC_MOVED" -eq 1 ] && [ -d "$OLD_OC" ] && [ "$restore_oc" -eq 1 ]; then
            if [ -e "$EFI_MOUNT_POINT/EFI/OC" ]; then
                log_error "Cannot restore the previous OC folder because the destination still exists."
                ROLLBACK_FAILED=1
                restore_oc=0
            fi
        fi
        if [ "$OLD_OC_MOVED" -eq 1 ] && [ -d "$OLD_OC" ] && [ "$restore_oc" -eq 1 ]; then
            if ! mv "$OLD_OC" "$EFI_MOUNT_POINT/EFI/OC"; then
                log_error "Could not restore the previous OC folder from $OLD_OC."
                ROLLBACK_FAILED=1
            fi
        fi
    fi
    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
        rm -rf "$STAGE_DIR"
    fi
    if [ "$ROLLBACK_FAILED" -eq 1 ]; then
        log_error "ROLLBACK INCOMPLETE. Leave the EFI mounted and restore the _OLD folders manually."
    elif [ "$status" -ne 0 ] && [ "$MOUNTED_BY_SCRIPT" -eq 1 ] && [ -n "$TARGET_PARTITION" ]; then
        diskutil unmount "$TARGET_PARTITION" >/dev/null 2>&1 ||
            log_warn "Could not unmount $TARGET_PARTITION after the failure."
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
        log_error "Incomplete OpenCore EFI. Missing:$missing"
        return 1
    fi
    if ! plutil -lint "$source_path/OC/config.plist" >/dev/null 2>&1; then
        log_error "OC/config.plist is not a valid property list."
        return 1
    fi
    return 0
}

verify_staged_copy() {
    validate_efi "$STAGE_DIR" &&
        diff -qr "$EFI_SOURCE/BOOT" "$STAGE_DIR/BOOT" >/dev/null 2>&1 &&
        diff -qr "$EFI_SOURCE/OC" "$STAGE_DIR/OC" >/dev/null 2>&1
}

choose_efi_source() {
    printf 'OpenCore needs a hardware-specific config.plist, drivers, and kexts.\n'
    if validate_efi "$BUNDLED_EFI" 2>/dev/null; then
        printf 'Press Enter to use the bundled EFI, or enter another EFI folder path: '
    else
        log_warn "The bundled EFI is incomplete and cannot boot by itself."
        printf 'Enter or drag the path to a known-good EFI folder: '
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

for cmd in diskutil plutil ditto mv rm mkdir rmdir sed awk sync du df diff date; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

printf '%s======================================================%s\n' "$CYAN" "$NC"
printf '%s       OpenCore Bootloader Restoration Assistant      %s\n' "$CYAN" "$NC"
printf '%s======================================================%s\n\n' "$CYAN" "$NC"

choose_efi_source
SOURCE_KB=$(du -sk "$EFI_SOURCE/BOOT" "$EFI_SOURCE/OC" | awk '{total += $1} END {print total}')
case "$SOURCE_KB" in
    '' | *[!0-9]*) die "Could not determine the EFI source size." ;;
esac

log_info "EFI partitions:"
EFI_LIST=$(diskutil list | awk '$2 == "EFI" || $3 == "EFI" {print $NF}')
if [ -z "$EFI_LIST" ]; then
    log_error "No EFI partitions were found."
    exit 1
fi

set -- $EFI_LIST
COUNT=$#
i=1
for partition in "$@"; do
    PARENT=$(diskutil info "$partition" | awk -F: '/Part of Whole:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
    PARENT_INFO=$(diskutil info "$PARENT" 2>/dev/null || true)
    MODEL=$(printf '%s\n' "$PARENT_INFO" | awk -F: '/Media Name:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
    SIZE=$(printf '%s\n' "$PARENT_INFO" | awk -F: '/Disk Size:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
    printf '  [%d] %-12s %s %s\n' "$i" "$partition" "${MODEL:-Unknown disk}" "${SIZE:-}"
    i=$((i + 1))
done

printf 'Select the EFI partition [1-%d], or q to quit: ' "$COUNT"
read -r SELECTION
[ "$SELECTION" = "q" ] && exit 0
case "$SELECTION" in
    '' | *[!0-9]*)
        log_error "Invalid selection."
        exit 1
        ;;
esac
if [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "$COUNT" ]; then
    log_error "Selection is outside the displayed range."
    exit 1
fi

i=1
for partition in "$@"; do
    if [ "$i" -eq "$SELECTION" ]; then
        TARGET_PARTITION=$partition
        break
    fi
    i=$((i + 1))
done

printf '\n'
diskutil info "$TARGET_PARTITION" | awk -F: '/Device Node:|Part of Whole:|Volume Name:|Disk Size:/ {print}'
log_warn "This will replace EFI/BOOT and EFI/OC on $TARGET_PARTITION. EFI/APPLE is preserved."
printf 'Type RESTORE-%s to continue: ' "$TARGET_PARTITION"
read -r CONFIRM
if [ "$CONFIRM" != "RESTORE-$TARGET_PARTITION" ]; then
    log_info "Cancelled; no changes were made."
    exit 0
fi

CONFIRMED_INFO=$(diskutil info "$TARGET_PARTITION" 2>/dev/null) || die "The selected EFI partition disappeared after confirmation."
CONFIRMED_ID=$(printf '%s\n' "$CONFIRMED_INFO" | awk -F: '/Device Identifier:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
CONFIRMED_CONTENT=$(printf '%s\n' "$CONFIRMED_INFO" | awk -F: '/Content \(IOContent\):/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
if [ "$CONFIRMED_ID" != "$TARGET_PARTITION" ] || [ "$CONFIRMED_CONTENT" != "EFI" ]; then
    die "The selected target is no longer the expected EFI partition. No files were changed."
fi

MOUNT_STATUS=$(diskutil info "$TARGET_PARTITION" | awk -F: '/Mounted:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
if [ "$MOUNT_STATUS" != "Yes" ]; then
    log_info "Mounting $TARGET_PARTITION..."
    diskutil mount "$TARGET_PARTITION" >/dev/null || {
        log_error "Failed to mount $TARGET_PARTITION."
        exit 1
    }
    MOUNTED_BY_SCRIPT=1
fi

EFI_MOUNT_POINT=$(diskutil info "$TARGET_PARTITION" | awk -F: '/Mount Point:/ {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
if [ -z "$EFI_MOUNT_POINT" ] || [ ! -d "$EFI_MOUNT_POINT" ]; then
    log_error "Could not determine the EFI mount point."
    exit 1
fi
log_success "Mounted at $EFI_MOUNT_POINT"

AVAILABLE_KB=$(df -kP "$EFI_MOUNT_POINT" | awk 'NR == 2 {print $4}')
case "$AVAILABLE_KB" in
    '' | *[!0-9]*) die "Could not determine free space on $TARGET_PARTITION." ;;
esac
if [ "$AVAILABLE_KB" -le $((SOURCE_KB + 1024)) ]; then
    die "Staging needs ${SOURCE_KB} KiB, but $TARGET_PARTITION has only ${AVAILABLE_KB} KiB free."
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)_$$"
mkdir -p "$EFI_MOUNT_POINT/EFI" || die "Could not create the EFI directory on $TARGET_PARTITION."
STAGE_DIR="$EFI_MOUNT_POINT/EFI/.restore_stage_$TIMESTAMP"
mkdir "$STAGE_DIR" || die "Could not create the staging directory."

log_info "Staging and verifying the new OpenCore files..."
ditto "$EFI_SOURCE/BOOT" "$STAGE_DIR/BOOT" || die "Failed to stage the BOOT folder."
ditto "$EFI_SOURCE/OC" "$STAGE_DIR/OC" || die "Failed to stage the OC folder."
verify_staged_copy || {
    log_error "Staged files failed verification; the existing EFI was not changed."
    exit 1
}

if [ -d "$EFI_MOUNT_POINT/EFI/BOOT" ]; then
    OLD_BOOT="$EFI_MOUNT_POINT/EFI/BOOT_OLD_$TIMESTAMP"
    [ ! -e "$OLD_BOOT" ] || die "Backup destination already exists: $OLD_BOOT"
    mv "$EFI_MOUNT_POINT/EFI/BOOT" "$OLD_BOOT" || die "Could not preserve the previous BOOT folder."
    OLD_BOOT_MOVED=1
fi
if [ -d "$EFI_MOUNT_POINT/EFI/OC" ]; then
    OLD_OC="$EFI_MOUNT_POINT/EFI/OC_OLD_$TIMESTAMP"
    [ ! -e "$OLD_OC" ] || die "Backup destination already exists: $OLD_OC"
    mv "$EFI_MOUNT_POINT/EFI/OC" "$OLD_OC" || die "Could not preserve the previous OC folder."
    OLD_OC_MOVED=1
fi

mv "$STAGE_DIR/BOOT" "$EFI_MOUNT_POINT/EFI/BOOT" || die "Could not install the staged BOOT folder."
NEW_BOOT_MOVED=1
mv "$STAGE_DIR/OC" "$EFI_MOUNT_POINT/EFI/OC" || die "Could not install the staged OC folder."
NEW_OC_MOVED=1
validate_efi "$EFI_MOUNT_POINT/EFI" || die "Installed EFI validation failed; rollback will be attempted."
INSTALL_COMMITTED=1
if ! rmdir "$STAGE_DIR"; then
    log_warn "Could not remove the empty staging directory; cleaning it separately."
    rm -rf "$STAGE_DIR" || log_warn "Manual cleanup may be needed at $STAGE_DIR."
fi
STAGE_DIR=""
sync || die "The EFI was installed, but filesystem synchronization failed."

log_success "OpenCore restored. Previous BOOT/OC folders remain beside it with _OLD_$TIMESTAMP names."
if [ "$MOUNTED_BY_SCRIPT" -eq 1 ]; then
    printf 'Unmount the EFI partition now? [Y/n]: '
    read -r UNMOUNT_CHOICE
    case "$UNMOUNT_CHOICE" in
        [nN]*) ;;
        *)
            if diskutil unmount "$TARGET_PARTITION" >/dev/null; then
                MOUNTED_BY_SCRIPT=0
                log_success "EFI partition unmounted."
            else
                log_warn "Could not unmount $TARGET_PARTITION; leave it connected until writes finish."
            fi
            ;;
    esac
fi

printf 'Clear NVRAM now? [y/N]: '
read -r CLEAR_CHOICE
case "$CLEAR_CHOICE" in
    [yY]*)
        if command -v nvram >/dev/null 2>&1 && nvram -c; then
            log_success "NVRAM cleared."
        else
            log_warn "NVRAM could not be cleared automatically."
        fi
        ;;
esac

printf 'Shut down now for a cold boot? [y/N]: '
read -r SHUTDOWN_CHOICE
case "$SHUTDOWN_CHOICE" in
    [yY]*)
        if command -v shutdown >/dev/null 2>&1; then
            shutdown -h now
        else
            log_warn "shutdown command is unavailable; shut down from the Apple menu."
        fi
        ;;
    *) log_info "When ready, shut down fully and start while holding Option to choose EFI Boot." ;;
esac
