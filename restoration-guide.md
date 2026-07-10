# Restoring a Missing OpenCore Boot Option from macOS Recovery

This guide walks through restoring the **OpenCore boot option** when it disappears after a macOS update or Recovery operation. It assumes you:

- Can boot into **macOS Recovery** on the target machine
- Have either:
  - A copy of **OpenCore-Patcher.app** on your macOS volume **or**
  - Access to the official OpenCore release ZIP, e.g.:\
    `https://github.com/acidanthera/OpenCorePkg/releases/download/1.0.6/OpenCore-1.0.6-RELEASE.zip`

---

## 1. Concepts & Goal

UEFI firmware boots from a small **EFI partition** (usually \~200 MB, FAT32) that contains:

```text
EFI/
 ├── APPLE/      ← Apple’s stuff (keep this!)
 ├── BOOT/       ← Fallback loader (BOOTx64.efi)
 └── OC/         ← OpenCore (OpenCore.efi, config.plist, etc.)
```

After some macOS updates or Recovery operations, custom UEFI entries (like OpenCore) may be wiped. Our goal is to:

1. Mount the EFI partition
2. Put a valid **EFI/OC** folder there
3. Ensure **EFI/BOOT/BOOTx64.efi** points to OpenCore
4. Clear NVRAM so firmware rescans and finds it again

All of this is done **from Terminal inside macOS Recovery**.

---

## 2. Open Terminal in Recovery

1. Boot into **macOS Recovery** (hold Power / Cmd+R / Option+Cmd+R depending on machine).
2. On the top menu bar, go to **Utilities → Terminal**.

We’ll do everything from here.

---

## 3. Identify the EFI Partition & macOS Volume

In Terminal:

```bash
diskutil list
```

Look for:

- Your main macOS APFS container (often `disk0`)
- The **EFI** partition on that same disk (usually `disk0s1`, \~200 MB, type “EFI”)

Example:

```text
/dev/disk0 (GUID Partition Scheme)
   1: EFI EFI                 209.7 MB  disk0s1
   2: Apple_APFS Container    XXX.X GB  disk0s2
```

Also note the name of your macOS volume (e.g. `Macintosh HD` or `Macintosh HD - Data`).

We’ll assume:

- EFI partition: `disk0s1`
- macOS volume: `Macintosh HD`

Adjust the commands if your identifiers are different.

---

## 4. Mount the EFI Partition

Still in Terminal:

```bash
diskutil mount disk0s1
```

If successful, EFI is usually mounted at:

```text
/Volumes/EFI
```

Check the contents:

```bash
ls /Volumes/EFI
ls /Volumes/EFI/EFI
```

You may see something like:

```text
APPLE
BOOT
OC
```

If `EFI` doesn’t exist, we’ll create it when copying OpenCore.

---

## 5. Option A – Use a Previously Generated OpenCore EFI

Use an EFI folder that was previously generated for this exact Mac and was known to boot. A generic OpenCore release or files copied from inside an application bundle are not substitutes for the generated `config.plist`, drivers, and kexts.

### 5.1. Locate the backup

Mount the USB or volume containing your backup and verify its layout. Replace `RESCUE` with its actual volume name:

```bash
ls "/Volumes/RESCUE/EFI/BOOT/BOOTx64.efi"
ls "/Volumes/RESCUE/EFI/OC/OpenCore.efi"
ls "/Volumes/RESCUE/EFI/OC/config.plist"
```

All three files must exist. Keep using the same generated EFI as a unit; mixing a configuration with binaries from a different OpenCore version can prevent booting.

### 5.2. Backup existing EFI (optional but recommended)

```bash
BACKUP_DIR="/Volumes/RESCUE/EFI_BACKUPS/EFI_$(date +%s)"
mkdir -p "$BACKUP_DIR"
cp -R /Volumes/EFI/EFI "$BACKUP_DIR/"
```

### 5.3. Copy the OpenCore EFI to the system EFI partition

```bash
cp -R "/Volumes/RESCUE/EFI" /Volumes/EFI/
```

After this, you should have:

```text
/Volumes/EFI/EFI/OC/OpenCore.efi
/Volumes/EFI/EFI/BOOT/BOOTx64.efi
```

Both files, plus `/Volumes/EFI/EFI/OC/config.plist`, must be present before attempting to boot.

---

## 6. Option B – Use the Official OpenCorePkg ZIP

OpenCorePkg can update an existing, known-good EFI, but it does not provide a configuration for your hardware. Use the exact release required by your configuration and download it from the official Acidanthera releases page.

### 6.1. Get the ZIP into Recovery

You have a few options:

- **From another machine**: Download the ZIP, put it on a USB drive, plug it into the Hackintosh, then in Recovery:
  - Use `diskutil list` to find the USB volume
  - Mount it: `diskutil mount diskXsY`
- **From Recovery via network**: Download the exact release URL you selected on another device. Do not guess a version number during recovery.

### 6.2. Unzip and locate the EFI folder

```bash
cd /tmp
unzip OpenCore-*-RELEASE.zip
cd OpenCore-*-RELEASE
ls
```

Typically, you’ll see something like:

- `X64/EFI/OC/...`
- `X64/EFI/BOOT/BOOTx64.efi`

### 6.3. **Important Configuration Warning**

The release provides OpenCore binaries and `Docs/Sample.plist`. It does not place a ready-to-use `config.plist` in `X64/EFI/OC`.

In most cases you should **NOT** simply use the sample config. Instead:

- Reuse your previous working **config.plist**, **Kexts**, and machine-specific ACPI files.
- Update OpenCore, its drivers, tools, and configuration keys as one compatible set by following the release documentation.

If you don’t have a previous config, follow the Dortania guide later to build a correct config from scratch.

### 6.4. Update an Existing EFI

Start from a backup of your complete working EFI. The target layout remains:

```text
/Volumes/EFI/EFI/OC/          ← Your config.plist, Kexts, Drivers, Tools
/Volumes/EFI/EFI/OC/OpenCore.efi
/Volumes/EFI/EFI/BOOT/BOOTx64.efi
```

Do not overwrite this layout with `X64/EFI` and do not update only `OpenCore.efi`. Version-mismatched drivers or configuration keys can stop OpenCore before the picker appears. Complete the upgrade on a working machine, validate it, and then use the resulting EFI as the source for this kit.

---

## 7. Verify the Fallback Loader

Many UEFI firmwares will always attempt to boot:

```text
EFI/BOOT/BOOTx64.efi
```

Use the `BOOTx64.efi` supplied with the same OpenCore build as the rest of your EFI. It is a separate loader; do not replace it with a renamed copy of `OpenCore.efi`.

```bash
ls -l /Volumes/EFI/EFI/BOOT/BOOTx64.efi
ls -l /Volumes/EFI/EFI/OC/OpenCore.efi
ls -l /Volumes/EFI/EFI/OC/config.plist
```

If any file is missing, return to your complete known-good EFI source and copy the matching folder again.

---

## 8. Keep the APPLE Folder – Don’t Delete It

You may see an `APPLE` folder inside `EFI`:

```text
/Volumes/EFI/EFI/APPLE
```

This is part of Apple’s own boot/update infrastructure. **Do not delete it.** It does not interfere with OpenCore.

Your final EFI layout will typically be:

```text
EFI/
 ├── APPLE/             ← Keep
 ├── BOOT/              ← Contains BOOTx64.efi (OpenCore)
 └── OC/                ← Full OpenCore setup
```

---

## 9. Clear NVRAM from Recovery

To make sure firmware forgets stale boot entries and rescans the EFI partition, reset NVRAM from Recovery Terminal:

```bash
nvram -c
```

This clears NVRAM variables (including custom boot entries). On next boot, the firmware should:

1. Look for `EFI/BOOT/BOOTx64.efi`
2. Load OpenCore

---

## 10. Reboot and Test

Type:

```bash
reboot
```

On startup, you should now see the **OpenCore boot picker**.

If your firmware uses a boot menu key (e.g., `F8`, `F11`, `F12`, etc.), you can also:

- Open the one-time boot menu
- Choose the UEFI entry corresponding to your drive (often something like "UEFI OS" or the drive’s model name)

It should chain into OpenCore through `BOOTx64.efi`.

---

## 11. If OpenCore Still Doesn’t Show: BIOS-Level Fix

If you **still** don’t see OpenCore after all steps above, your UEFI firmware may not be scanning the fallback path correctly. Then you’ll need to:

1. Enter BIOS/UEFI Setup

2. Find **Add Boot Option** / **Add UEFI Boot Entry** / similar

3. Browse to your disk’s EFI partition and select:

   ```text
   \EFI\OC\OpenCore.efi
   ```

4. Name the entry **OpenCore**

5. Move this entry to the **top** of the boot order

Save and exit. You should now boot into OpenCore.

---

## 12. Quick Reference – Commands Summary

Below is a condensed command sequence (adjust `disk0s1` and volume names as needed):

```bash
# 1. List disks
diskutil list

# 2. Mount EFI
diskutil mount disk0s1

# 3. (Option A) Copy a complete, previously generated EFI
cp -R "/Volumes/RESCUE/EFI" /Volumes/EFI/

# 4. Verify the complete layout
ls /Volumes/EFI/EFI/BOOT/BOOTx64.efi
ls /Volumes/EFI/EFI/OC/OpenCore.efi
ls /Volumes/EFI/EFI/OC/config.plist

# 5. Clear NVRAM
nvram -c

# 6. Reboot
reboot
```

Do not substitute the official package's generic `X64/EFI` tree for the complete generated EFI in this sequence.

---

## 13. Safety Tips

- Always keep a **USB installer** with a known-good OpenCore EFI for emergencies.
- Back up your **working EFI folder** (especially `config.plist` and Kexts) somewhere safe.
- When updating OpenCore from releases like `OpenCore-1.0.6-RELEASE.zip`, prefer:
  - **Reusing your config** and only updating binaries
  - Following the **Dortania** guide to update config keys when moving between versions.

Once this is in place, losing the OpenCore entry after a macOS update becomes a minor inconvenience instead of a disaster.

