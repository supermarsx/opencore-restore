#!/bin/sh

# Exercises Linux USB creation with mocked block-device commands.

set -u
cd "$(dirname "$0")" || exit 1
TEST_DIR="$PWD/test_linux_usb"
MOCK_BIN="$TEST_DIR/bin"
RUNTIME="$TEST_DIR/runtime"
MOCK_LOG="$TEST_DIR/device.log"
MOCK_INFO_COUNT="$TEST_DIR/info.count"
MOCK_CAPTURE="$TEST_DIR/capture"
export MOCK_LOG MOCK_INFO_COUNT MOCK_CAPTURE

rm -rf "$TEST_DIR"
mkdir -p "$MOCK_BIN" "$RUNTIME/BOOTEFIX64/EFI/BOOT" "$RUNTIME/BOOTEFIX64/EFI/OC" "$MOCK_CAPTURE"
touch "$RUNTIME/BOOTEFIX64/EFI/BOOT/BOOTx64.efi" "$RUNTIME/BOOTEFIX64/EFI/OC/OpenCore.efi"
printf '<plist version="1.0"><dict/></plist>\n' >"$RUNTIME/BOOTEFIX64/EFI/OC/config.plist"
cp ../create_usb_linux.sh "$RUNTIME/create_usb_linux.sh"

cat >"$MOCK_BIN/id" <<'EOF'
#!/bin/sh
[ "$1" = "-u" ] && printf '0\n'
EOF

cat >"$MOCK_BIN/lsblk" <<'EOF'
#!/bin/sh
printf 'lsblk %s\n' "$*" >>"$MOCK_LOG"
case "$*" in
    '-dpno NAME,TRAN,RM,SIZE,TYPE') printf '/dev/mock usb 1 16G disk\n' ;;
    '-dno TYPE /dev/mock') printf 'disk\n' ;;
    '-dnbo SIZE,MODEL,SERIAL,WWN,TRAN,RM,TYPE /dev/mock')
        count=0
        [ -f "$MOCK_INFO_COUNT" ] && count=$(cat "$MOCK_INFO_COUNT")
        count=$((count + 1))
        printf '%s\n' "$count" >"$MOCK_INFO_COUNT"
        size=16000000000
        if [ "${DEVICE_CHANGED:-0}" = "1" ] && [ "$count" -ge 2 ]; then size=32000000000; fi
        printf '%s Mock_USB SERIAL WWN usb 1 disk\n' "$size"
        ;;
    '-dnbo SIZE /dev/mock') printf '16000000000\n' ;;
    '-dno TRAN /dev/mock') printf 'usb\n' ;;
    '-dno RM /dev/mock') printf '1\n' ;;
    '-sno NAME,TYPE /dev/system1') printf 'system1 part\nsystem disk\n' ;;
    '-sno NAME,TYPE /dev/source1') printf 'source1 part\nsource disk\n' ;;
    '-dno NAME,SIZE,MODEL,TRAN,RM /dev/mock') printf 'mock 16G Mock_USB usb 1\n' ;;
    '-lnpo NAME,MOUNTPOINT /dev/mock') printf '/dev/mock\n' ;;
    '-lnpo NAME,TYPE /dev/mock') printf '/dev/mock disk\n/dev/mock1 part\n' ;;
    '-no FSTYPE /dev/mock1') printf 'vfat\n' ;;
    '-no PARTTYPE /dev/mock1') printf 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b\n' ;;
    *) exit 1 ;;
esac
EOF

cat >"$MOCK_BIN/findmnt" <<'EOF'
#!/bin/sh
case "$*" in
    '-no SOURCE /') printf '/dev/system1\n' ;;
    '-no SOURCE -T '*) printf '/dev/source1\n' ;;
    *) exit 1 ;;
esac
EOF

for command_name in parted mkfs.vfat mount partprobe udevadm; do
    cat >"$MOCK_BIN/$command_name" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >>"$MOCK_LOG"
exit 0
EOF
done

cat >"$MOCK_BIN/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >>"$MOCK_LOG"
rm -rf "$MOCK_CAPTURE/EFI"
[ -d "$1/EFI" ] && cp -R "$1/EFI" "$MOCK_CAPTURE/EFI"
rm -rf "$1/EFI"
EOF

cat >"$MOCK_BIN/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/mock1 16000000 1 15999999 1%% /tmp/mock\n'
EOF

cat >"$MOCK_BIN/xmllint" <<'EOF'
#!/bin/sh
last=''
for argument in "$@"; do last=$argument; done
[ -f "$last" ] && grep -q '<plist[ >]' "$last"
EOF

chmod +x "$MOCK_BIN"/* "$RUNTIME/create_usb_linux.sh"
export PATH="$MOCK_BIN:$PATH"
failures=0

printf 'Running mocked Linux USB success test...\n'
(
    cd "$RUNTIME" || exit 1
    printf '%s\n/dev/mock\nERASE-mock\n' "$RUNTIME/BOOTEFIX64/EFI" | OPENCORE_ALLOW_MOCK_DEVICES=1 ./create_usb_linux.sh
) || failures=$((failures + 1))

if [ -f "$MOCK_CAPTURE/EFI/OC/config.plist" ] && [ ! -d "$MOCK_CAPTURE/EFI/EFI" ]; then
    printf '[PASS] Linux creator produced USB/EFI without nesting\n'
else
    printf '[FAIL] Linux creator produced an invalid copy layout\n'
    failures=$((failures + 1))
fi

printf 'Running mocked Linux device-change test...\n'
rm -rf "$MOCK_CAPTURE/EFI" "$MOCK_INFO_COUNT"
: >"$MOCK_LOG"
if (
    cd "$RUNTIME" || exit 1
    printf '%s\n/dev/mock\nERASE-mock\n' "$RUNTIME/BOOTEFIX64/EFI" | OPENCORE_ALLOW_MOCK_DEVICES=1 DEVICE_CHANGED=1 ./create_usb_linux.sh
); then
    printf '[FAIL] Linux creator accepted a changed target device\n'
    failures=$((failures + 1))
elif grep -q '^parted ' "$MOCK_LOG"; then
    printf '[FAIL] Linux creator partitioned after device identity changed\n'
    failures=$((failures + 1))
else
    printf '[PASS] Linux creator rejected changed target before partitioning\n'
fi

rm -rf "$TEST_DIR"
[ "$failures" -eq 0 ] || exit 1
printf 'All mocked Linux USB tests passed.\n'
