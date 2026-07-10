#!/bin/sh

# Non-destructive integration tests for restore.sh using mocked macOS commands.

set -u

cd "$(dirname "$0")" || exit 1
TEST_DIR="$PWD/test_env"
MOCK_BIN="$TEST_DIR/bin"
RUNTIME="$TEST_DIR/runtime"
MOCK_EFI_MOUNT="$RUNTIME/Volumes/EFI"
export MOCK_EFI_MOUNT

rm -rf "$TEST_DIR"
mkdir -p "$MOCK_BIN" "$MOCK_EFI_MOUNT/EFI/BOOT" "$MOCK_EFI_MOUNT/EFI/OC"
mkdir -p "$RUNTIME/BOOTEFIX64/EFI/BOOT" "$RUNTIME/BOOTEFIX64/EFI/OC"

touch "$RUNTIME/BOOTEFIX64/EFI/BOOT/BOOTx64.efi"
touch "$RUNTIME/BOOTEFIX64/EFI/OC/OpenCore.efi"
cat >"$RUNTIME/BOOTEFIX64/EFI/OC/config.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict/></plist>
EOF
reset_target() {
    rm -rf "$MOCK_EFI_MOUNT/EFI"
    mkdir -p "$MOCK_EFI_MOUNT/EFI/BOOT" "$MOCK_EFI_MOUNT/EFI/OC"
    touch "$MOCK_EFI_MOUNT/EFI/BOOT/old_boot.efi"
    touch "$MOCK_EFI_MOUNT/EFI/OC/old_oc.efi"
}
reset_target

cp ../restore.sh "$RUNTIME/restore.sh"
chmod +x "$RUNTIME/restore.sh"

cat >"$MOCK_BIN/diskutil" <<'EOF'
#!/bin/sh
case "$1" in
    list)
        printf '/dev/disk0 (internal, physical):\n'
        printf '   1: EFI EFI 209.7 MB disk0s1\n'
        ;;
    info)
        if [ "$2" = "disk0s1" ]; then
            printf '   Device Node: /dev/disk0s1\n'
            printf '   Device Identifier: disk0s1\n'
            printf '   Content (IOContent): EFI\n'
            printf '   Part of Whole: disk0\n'
            printf '   Volume Name: EFI\n'
            printf '   Disk Size: 209.7 MB\n'
            printf '   Mounted: No\n'
            printf '   Mount Point: %s\n' "$MOCK_EFI_MOUNT"
        else
            printf '   Media Name: Mock Internal Disk\n'
            printf '   Disk Size: 500.0 GB\n'
        fi
        ;;
    mount|unmount) exit 0 ;;
    *) exit 1 ;;
esac
EOF

cat >"$MOCK_BIN/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
if [ "${LOW_SPACE:-0}" = "1" ]; then
    printf '/dev/mock 1000 999 1 99%% %s\n' "$MOCK_EFI_MOUNT"
else
    printf '/dev/mock 1000000 1 999999 1%% %s\n' "$MOCK_EFI_MOUNT"
fi
EOF

cat >"$MOCK_BIN/ditto" <<'EOF'
#!/bin/sh
cp -R "$1" "$2"
EOF

cat >"$MOCK_BIN/plutil" <<'EOF'
#!/bin/sh
last=""
for argument in "$@"; do last=$argument; done
[ -f "$last" ]
EOF

REAL_MV=$(command -v mv)
export REAL_MV
cat >"$MOCK_BIN/mv" <<'EOF'
#!/bin/sh
case "$1" in
    */.restore_stage_*/OC)
        if [ "${FAIL_OC_INSTALL:-0}" = "1" ]; then
            exit 71
        fi
        ;;
esac
exec "$REAL_MV" "$@"
EOF

chmod +x "$MOCK_BIN/diskutil" "$MOCK_BIN/df" "$MOCK_BIN/ditto" "$MOCK_BIN/plutil" "$MOCK_BIN/mv"
export PATH="$MOCK_BIN:$PATH"

failures=0
assert_file() {
    if [ -f "$1" ]; then
        printf '[PASS] %s\n' "$2"
    else
        printf '[FAIL] %s\n' "$2"
        failures=$((failures + 1))
    fi
}

printf 'Running successful staged-restore test...\n'
(
    cd "$RUNTIME" || exit 1
    printf '\n1\nRESTORE-disk0s1\n\n\n\n' | ./restore.sh
)
restore_status=$?
if [ "$restore_status" -eq 0 ]; then
    printf '[PASS] restore exited successfully\n'
else
    printf '[FAIL] restore exited with %s\n' "$restore_status"
    failures=$((failures + 1))
fi

assert_file "$MOCK_EFI_MOUNT/EFI/BOOT/BOOTx64.efi" 'new BOOT loader installed'
assert_file "$MOCK_EFI_MOUNT/EFI/OC/OpenCore.efi" 'new OpenCore binary installed'
assert_file "$MOCK_EFI_MOUNT/EFI/OC/config.plist" 'config.plist installed'

old_boot_found=0
old_oc_found=0
for old_folder in "$MOCK_EFI_MOUNT"/EFI/BOOT_OLD_*; do
    [ -f "$old_folder/old_boot.efi" ] && old_boot_found=1
done
for old_folder in "$MOCK_EFI_MOUNT"/EFI/OC_OLD_*; do
    [ -f "$old_folder/old_oc.efi" ] && old_oc_found=1
done
if [ "$old_boot_found" -eq 1 ] && [ "$old_oc_found" -eq 1 ]; then
    printf '[PASS] previous BOOT and OC folders preserved\n'
else
    printf '[FAIL] previous BOOT and OC folders were not preserved\n'
    failures=$((failures + 1))
fi

stage_found=0
for stage_folder in "$MOCK_EFI_MOUNT"/EFI/.restore_stage_*; do
    [ -d "$stage_folder" ] && stage_found=1
done
if [ "$stage_found" -eq 1 ]; then
    printf '[FAIL] staging directory was not cleaned up\n'
    failures=$((failures + 1))
else
    printf '[PASS] staging directory cleaned up\n'
fi

printf 'Running forced-install-failure rollback test...\n'
reset_target
(
    cd "$RUNTIME" || exit 1
    printf '\n1\nRESTORE-disk0s1\n' | FAIL_OC_INSTALL=1 ./restore.sh
)
rollback_status=$?
if [ "$rollback_status" -ne 0 ]; then
    printf '[PASS] injected install failure returned nonzero\n'
else
    printf '[FAIL] injected install failure unexpectedly succeeded\n'
    failures=$((failures + 1))
fi
assert_file "$MOCK_EFI_MOUNT/EFI/BOOT/old_boot.efi" 'previous BOOT restored after install failure'
assert_file "$MOCK_EFI_MOUNT/EFI/OC/old_oc.efi" 'previous OC restored after install failure'
if [ -f "$MOCK_EFI_MOUNT/EFI/BOOT/BOOTx64.efi" ]; then
    printf '[FAIL] partial BOOT installation remained after rollback\n'
    failures=$((failures + 1))
else
    printf '[PASS] partial BOOT installation removed during rollback\n'
fi

printf 'Running insufficient-space test...\n'
reset_target
(
    cd "$RUNTIME" || exit 1
    printf '\n1\nRESTORE-disk0s1\n' | LOW_SPACE=1 ./restore.sh
)
space_status=$?
if [ "$space_status" -ne 0 ]; then
    printf '[PASS] insufficient space returned nonzero\n'
else
    printf '[FAIL] insufficient space unexpectedly succeeded\n'
    failures=$((failures + 1))
fi
assert_file "$MOCK_EFI_MOUNT/EFI/BOOT/old_boot.efi" 'low-space failure left BOOT unchanged'
assert_file "$MOCK_EFI_MOUNT/EFI/OC/old_oc.efi" 'low-space failure left OC unchanged'

rm -rf "$TEST_DIR"
if [ "$failures" -ne 0 ]; then
    printf '%s test(s) failed.\n' "$failures"
    exit 1
fi
printf 'All restore tests passed.\n'
