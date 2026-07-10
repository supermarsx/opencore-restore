#!/bin/sh

# Exercises macOS USB creation with mocked disk commands; no real disk is touched.

set -u
cd "$(dirname "$0")" || exit 1
TEST_DIR="$PWD/test_macos_usb"
MOCK_BIN="$TEST_DIR/bin"
RUNTIME="$TEST_DIR/runtime"
MOCK_MOUNT="$RUNTIME/Volumes/EFI"
MOCK_LOG="$TEST_DIR/diskutil.log"
MOCK_INFO_COUNT="$TEST_DIR/info.count"
export MOCK_MOUNT MOCK_LOG MOCK_INFO_COUNT

rm -rf "$TEST_DIR"
mkdir -p "$MOCK_BIN" "$RUNTIME/BOOTEFIX64/EFI/BOOT" "$RUNTIME/BOOTEFIX64/EFI/OC" "$MOCK_MOUNT"
touch "$RUNTIME/BOOTEFIX64/EFI/BOOT/BOOTx64.efi" "$RUNTIME/BOOTEFIX64/EFI/OC/OpenCore.efi"
printf '<plist version="1.0"><dict/></plist>\n' >"$RUNTIME/BOOTEFIX64/EFI/OC/config.plist"
cp ../create_usb.sh "$RUNTIME/create_usb.sh"

cat >"$MOCK_BIN/diskutil" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MOCK_LOG"
case "$1" in
    list)
        if [ "${2:-}" = "external" ]; then
            printf '/dev/disk2 (external, physical):\n'
            printf '   0: GUID_partition_scheme 16.0 GB disk2\n'
        else
            printf '/dev/disk2 (external, physical):\n'
            printf '   1: EFI EFI 209.7 MB disk2s1\n'
        fi
        ;;
    info)
        case "$2" in
            /dev/disk2)
                count=0
                [ -f "$MOCK_INFO_COUNT" ] && count=$(cat "$MOCK_INFO_COUNT")
                count=$((count + 1))
                printf '%s\n' "$count" >"$MOCK_INFO_COUNT"
                name='Mock USB'
                if [ "${DEVICE_CHANGED:-0}" = "1" ] && [ "$count" -ge 2 ]; then name='Changed USB'; fi
                printf '   Whole: Yes\n'
                printf '   Internal: No\n'
                printf '   Device Location: External\n'
                printf '   Media Name: %s\n' "$name"
                printf '   Disk Size: 16.0 GB (16000000000 Bytes)\n'
                ;;
            /dev/disk2s1)
                printf '   Mount Point: %s\n' "$MOCK_MOUNT"
                ;;
        esac
        ;;
    eraseDisk|mount|unmount|eject) exit 0 ;;
    *) exit 1 ;;
esac
EOF

cat >"$MOCK_BIN/ditto" <<'EOF'
#!/bin/sh
mkdir -p "$2"
cp -R "$1"/. "$2/"
EOF

cat >"$MOCK_BIN/plutil" <<'EOF'
#!/bin/sh
last=''
for argument in "$@"; do last=$argument; done
[ -f "$last" ]
EOF

cat >"$MOCK_BIN/df" <<'EOF'
#!/bin/sh
last=''
for argument in "$@"; do last=$argument; done
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
case "$last" in
    "$MOCK_MOUNT") printf '/dev/disk2s1 200000 1 199999 1%% %s\n' "$MOCK_MOUNT" ;;
    *) printf '/dev/disk9s1 1000000 1 999999 1%% /source\n' ;;
esac
EOF

chmod +x "$MOCK_BIN"/* "$RUNTIME/create_usb.sh"
export PATH="$MOCK_BIN:$PATH"
failures=0

printf 'Running mocked macOS USB success test...\n'
(
    cd "$RUNTIME" || exit 1
    printf '\ndisk2\nERASE-disk2\n\n' | ./create_usb.sh
) || failures=$((failures + 1))

if [ -f "$MOCK_MOUNT/EFI/OC/config.plist" ] && [ ! -d "$MOCK_MOUNT/EFI/EFI" ]; then
    printf '[PASS] macOS creator produced USB/EFI without nesting\n'
else
    printf '[FAIL] macOS creator produced an invalid copy layout\n'
    failures=$((failures + 1))
fi

printf 'Running mocked macOS device-change test...\n'
rm -rf "$MOCK_MOUNT/EFI" "$MOCK_INFO_COUNT"
: >"$MOCK_LOG"
if (
    cd "$RUNTIME" || exit 1
    printf '\ndisk2\nERASE-disk2\n' | DEVICE_CHANGED=1 ./create_usb.sh
); then
    printf '[FAIL] macOS creator accepted a changed target device\n'
    failures=$((failures + 1))
elif grep -q '^eraseDisk ' "$MOCK_LOG"; then
    printf '[FAIL] macOS creator erased after device identity changed\n'
    failures=$((failures + 1))
else
    printf '[PASS] macOS creator rejected changed target before erase\n'
fi

rm -rf "$TEST_DIR"
[ "$failures" -eq 0 ] || exit 1
printf 'All mocked macOS USB tests passed.\n'
