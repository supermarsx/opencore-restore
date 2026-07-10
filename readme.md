# OpenCore Bootloader Restoration Kit

<!-- Badges: CI | Stars | Forks | Watchers | Repo Size | License | Built With -->
[![CI](https://github.com/supermarsx/opencore-restore/actions/workflows/ci.yml/badge.svg)](https://github.com/supermarsx/opencore-restore/actions/workflows/ci.yml)
[![GitHub stars](https://img.shields.io/github/stars/supermarsx/opencore-restore?style=flat-square)](https://github.com/supermarsx/opencore-restore/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/supermarsx/opencore-restore?style=flat-square)](https://github.com/supermarsx/opencore-restore/network/members)
[![Watchers](https://img.shields.io/github/watchers/supermarsx/opencore-restore?style=flat-square)](https://github.com/supermarsx/opencore-restore/watchers)
[![Repo size](https://img.shields.io/github/repo-size/supermarsx/opencore-restore?style=flat-square)](https://github.com/supermarsx/opencore-restore)
[![License](https://img.shields.io/github/license/supermarsx/opencore-restore?style=flat-square)](LICENSE.md)
[![Built with](https://img.shields.io/badge/built%20with-ShellScript-blue?style=flat-square)](https://github.com/acidanthera/OpenCorePkg)


## 🚨 Emergency Boot Rescue

**Did you accidentally update macOS and lose access to your system?**

This repository provides interactive tools for installing a known-good OpenCore EFI onto a rescue USB or an existing EFI partition. It does not generate an OpenCore configuration for your Mac.

> [!IMPORTANT]
> You must supply a complete EFI folder built for the target Mac. It must contain `EFI/BOOT/BOOTx64.efi`, `EFI/OC/OpenCore.efi`, and `EFI/OC/config.plist`. The files under `BOOTEFIX64` are an incomplete binary base and are not bootable by themselves. The scripts validate the source before allowing a disk to be changed.


## ⚡ Choose Your Recovery Method

Select the method that best fits your situation:

| Method | Requirements | Difficulty | Best For |
| :--- | :--- | :--- | :--- |
| **[1. Rescue USB](#1-rescue-usb-method-recommended)** | Another PC/Mac + USB Drive | ⭐ Easy | Most reliable method. |
| **[2. Local Recovery](#2-local-recovery-no-usb-no-internet)** | Known-good EFI on a mounted volume | ⭐⭐ Medium | No script download needed. |
| **[3. Official OpenCore Package](#3-official-opencore-package-advanced)** | Existing config + upgrade knowledge | ⭐⭐⭐ Hard | Updating an existing EFI, not initial rescue. |
| **[4. Automated EFI Restore](#4-automated-efi-restore-in-recovery)** | Recovery + known-good EFI | ⭐⭐ Medium | Safely installs and preserves the old EFI. |


## 1. Rescue USB Method (Recommended)

**Requirements:** Another computer (Windows/macOS/Linux), a USB drive, and a complete EFI folder previously built for the Mac you need to recover.

Download or clone this repository, extract it if necessary, and keep your known-good `EFI` folder somewhere accessible. The scripts ask for its path; on macOS and Windows you can drag the folder into the terminal window instead of typing the path.

### Automated Creation

We provide automated scripts for all major operating systems to easily create the rescue USB.

Each creator validates the complete EFI source before listing targets, rejects system disks and sources stored on the target, rechecks device identity after the final confirmation, verifies capacity and partition type, and compares the complete copied file tree. Any failure exits nonzero and reports whether the USB may be incomplete.

#### 🍎 macOS
1. Open Terminal and change to the extracted repository folder.
2. Run:
    ```bash
    sh ./create_usb.sh
    ```
3. Follow the prompts to select the EFI source and external disk. The script refuses internal disks.

#### 🪟 Windows
1. Open **PowerShell as Administrator** and change to the extracted repository folder.
2. Run:
    ```powershell
    powershell -ExecutionPolicy Bypass -File .\create_usb.ps1
    ```
3. Follow the prompts. Windows creates a 1 GiB FAT32 boot partition so the process also works on USB drives larger than 32 GiB.

#### 🐧 Linux
1. Open Terminal and change to the extracted repository folder.
2. Run with sudo:
    ```bash
    sudo sh ./create_usb_linux.sh
    ```
3. Follow the prompts. Only USB or removable whole disks are accepted.

### Manual Method
If you prefer to do it manually:
1. **Prepare USB:** Format a USB drive as **FAT32** using a GUID Partition Map (GPT).
2. **Copy Files:** Copy your complete, hardware-specific **`EFI`** folder to the **root** of the USB drive. The final path must be `USB/EFI/OC/config.plist`, not `USB/EFI/EFI/...`.
3.  **Boot:**
    *   Insert USB into the broken Mac.
    *   Hold **Option (Alt)** while powering on.
    *   Select **"EFI Boot"** (OpenCore logo).
    *   Select your macOS disk to boot.
4. **Fix:** Once in macOS, use the same OpenCore tool and configuration that created the working EFI to reinstall it to the internal disk.


## 2. Local Recovery (No USB, No Internet)

**Requirements:** A complete EFI previously generated for this Mac must be accessible on an unlocked macOS volume or another mounted volume.

1.  Boot into **macOS Recovery** (Hold `Cmd+R` or Power button).
2.  Open **Terminal** (Utilities > Terminal).
3.  **Identify your disks:**
    ```bash
    diskutil list
    ```
    *Note your EFI partition (e.g., `disk0s1`) and macOS Data volume identifier (e.g., `disk1s1` - look for "APFS Data").*
4.  **Unlock Data Volume (If Encrypted):**
    If you don't see your volume in `/Volumes` or it is encrypted (FileVault), unlock it:
    ```bash
    # Replace disk1s1 with your Data volume identifier
    diskutil apfs unlockVolume disk1s1
    ```
    *Enter your macOS user password when prompted.*
5.  **Mount EFI:**
    ```bash
    diskutil mount disk0s1
    ```
6. **Copy a previously generated EFI:** Mount the USB or volume containing your known-good EFI and copy that folder. Do not copy generic files from inside an application bundle; they may not include the configuration generated for this Mac.
    ```bash
    # Example only: replace RESCUE with the volume that contains your backup
    cp -R "/Volumes/RESCUE/EFI" /Volumes/EFI/
    ```
7.  **Clear NVRAM & Reboot:**
    It is critical to clear NVRAM so the firmware forgets the old broken boot entries.
    ```bash
    nvram -c
    ```
    Then, fully **shutdown** and power on again (cold boot) to ensure the new settings take effect.
    ```bash
    shutdown -h now
    ```


## 3. Official OpenCore Package (Advanced)

**Requirements:** A known-good `config.plist`, the matching kexts, and enough OpenCore upgrade knowledge to keep every binary and configuration key compatible.

The official OpenCorePkg release contains binaries and a sample plist, not a bootable configuration for your Mac. Do not copy its `X64/EFI` folder directly onto the target and expect it to boot. Download the exact release required by your existing configuration and follow the OpenCore upgrade documentation to update the complete binary/configuration set together. If you do not already have a working configuration, use a hardware-specific builder or guide before running these restore scripts.


## 4. Automated EFI Restore in Recovery

**Requirements:** macOS Recovery and a complete, known-good EFI folder accessible on a mounted USB or macOS volume. Internet access is needed only if the scripts are not already available locally.

1. Boot into **macOS Recovery**, open **Terminal**, and connect to Wi-Fi if you need to download the scripts.
2. Download this repository:
    ```bash
    cd /tmp
    curl -L -o opencore-restore.zip https://codeload.github.com/supermarsx/opencore-restore/zip/refs/heads/main
    unzip opencore-restore.zip
    ```
3. Run the restore assistant:
    ```bash
    cd opencore-restore-main
    sh ./restore.sh
    ```
4. When prompted, enter or drag the path to your complete EFI folder. The assistant makes you select the EFI partition, stages and verifies the files before replacement, preserves the previous `BOOT` and `OC` folders, and makes NVRAM clearing and shutdown optional.


## 📚 Detailed Manual Guide

For complex scenarios, troubleshooting, and detailed explanations of every command, please read our full **[Restoration Guide](restoration-guide.md)**.

## Testing

CI runs ShellCheck and `shfmt`, mocked success and failure-path integration tests for macOS, Linux, and restore workflows, and PowerShell tests under both Windows PowerShell 5.1 and current PowerShell. The tests verify device-replacement rejection, copy layout and integrity, low-space handling, staged restore, and rollback. Physical USB erasure is intentionally not performed by hosted CI.

## ⚠️ Disclaimer & No Warranty

**YOU ARE ON YOUR OWN.**

This software and guide are provided "AS IS", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages or other liability, whether in an action of contract, tort or otherwise, arising from, out of or in connection with the software or the use or other dealings in the software.

*   **Risk of Data Loss:** Modifying EFI partitions and bootloaders carries a risk of rendering your system unbootable or causing data loss.
*   **Backup Required:** Always backup your data before performing system modifications.
*   **Not Official:** This is a community-maintained rescue kit and is not affiliated with Apple Inc. or the OpenCore project.
