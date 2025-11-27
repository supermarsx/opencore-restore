# OpenCore Restoration Kit

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

This repository provides a "Rescue Kit" to help you boot back into macOS when your OpenCore installation has been overwritten, bypassed, or corrupted during a system update.

---

## ⚡ Choose Your Recovery Method

Select the method that best fits your situation:

| Method | Requirements | Difficulty | Best For |
| :--- | :--- | :--- | :--- |
| **[1. Rescue USB](#1-rescue-usb-method-recommended)** | Another PC/Mac + USB Drive | ⭐ Easy | Most reliable method. |
| **[2. Local Recovery](#2-local-recovery-no-usb-no-internet)** | `OpenCore-Patcher` app on disk | ⭐⭐ Medium | No USB or Internet needed. |
| **[3. Internet Recovery (Official)](#3-internet-recovery-no-usb-with-internet)** | Internet connection in Recovery | ⭐⭐⭐ Hard | Downloads generic OpenCore. |
| **[4. Internet Rescue Kit (Repo)](#4-internet-recovery-using-this-rescue-kit)** | Internet connection in Recovery | ⭐⭐ Medium | Downloads this specific rescue kit. |

---

## 1. Rescue USB Method (Recommended)

**Requirements:** Another computer (Windows/Mac/Linux) and a USB drive.

### Automated Creation

We provide automated scripts for all major operating systems to easily create the rescue USB.

#### 🍎 macOS
1.  Open Terminal.
2.  Run:
    ```bash
    ./create_usb.sh
    ```
3.  Follow the on-screen prompts.

#### 🪟 Windows
1.  Right-click `create_usb.ps1` and select **"Run with PowerShell"**.
2.  Follow the prompts to select your USB drive.
    *   *Note: Requires Administrator privileges.*

#### 🐧 Linux
1.  Open Terminal.
2.  Run with sudo:
    ```bash
    sudo ./create_usb_linux.sh
    ```
3.  Follow the prompts.

### Manual Method
If you prefer to do it manually:
1.  **Prepare USB:** Format a USB drive as **FAT32** (Scheme: GUID Partition Map / GPT).
2.  **Copy Files:** Copy the **`EFI`** folder from the `BOOTEFIX64` folder in this repository to the **root** of the USB drive.
3.  **Boot:**
    *   Insert USB into the broken Mac.
    *   Hold **Option (Alt)** while powering on.
    *   Select **"EFI Boot"** (OpenCore logo).
    *   Select your macOS disk to boot.
4.  **Fix:** Once in macOS, run OpenCore Patcher and "Install to Disk" to fix the internal drive.

---

## 2. Local Recovery (No USB, No Internet)

**Requirements:** You must have the **OpenCore Legacy Patcher** app installed in your Applications folder on the broken Mac.

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
6.  **Copy EFI from your Applications folder:**
    ```bash
    # Navigate to the Patcher's resources
    cd "/Volumes/Macintosh HD/Applications/OpenCore-Patcher.app/Contents/Resources"
    
    # Copy the EFI folder to your EFI partition
    cp -R EFI /Volumes/EFI/
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

---

## 3. Internet Recovery (No USB, With Internet)

**Requirements:** Working Wi-Fi or Ethernet in Recovery Mode.

1.  Boot into **macOS Recovery** and connect to Wi-Fi (top right corner).
2.  Open **Terminal**.
3.  **Mount EFI:**
    ```bash
    diskutil mount disk0s1
    ```
4.  **Download OpenCore:**
    ```bash
    cd /Volumes/EFI
    # Download OpenCore (Example for v1.6.0 - check for latest version URL)
    curl -L -O https://github.com/acidanthera/OpenCorePkg/releases/download/1.6.0/OpenCore-1.6.0-RELEASE.zip
    unzip OpenCore-*.zip
    ```
5.  **Install:**
    *   *Warning: This installs a generic config. Only use this if you know how to configure it or just need the .efi files.*
    ```bash
    cp -R X64/EFI /Volumes/EFI/
    ```
    *(See the [Detailed Guide](restoration-guide.md) for properly configuring `BOOTx64.efi`)*
6.  **Clear NVRAM & Reboot:**
    ```bash
    nvram -c
    shutdown -h now
    ```
    *Perform a cold boot (shutdown then power on).*

---

## 4. Internet Recovery (Using this Rescue Kit)

**Requirements:** Working Wi-Fi or Ethernet in Recovery Mode.

1.  Boot into **macOS Recovery** and connect to Wi-Fi.
2.  Open **Terminal**.
3.  **Mount EFI:**
    ```bash
    diskutil mount disk0s1
    ```
4.  **Download this Rescue Kit:**
    ```bash
    cd /tmp
    curl -L -o opencore-restore.zip https://codeload.github.com/supermarsx/opencore-restore/zip/refs/heads/main
    unzip opencore-restore.zip
    ```
5.  **Run the Automated Restore Script:**
    We have included a script to automate the process (detects EFI, backs up old files, installs new ones, and clears NVRAM).
    ```bash
    cd opencore-restore-main
    chmod +x restore.sh
    ./restore.sh
    ```
    *Follow the on-screen prompts.*

---

## 📚 Detailed Manual Guide

For complex scenarios, troubleshooting, and detailed explanations of every command, please read our full **[Restoration Guide](restoration-guide.md)**.

## ⚠️ Disclaimer & No Warranty

**YOU ARE ON YOUR OWN.**

This software and guide are provided "AS IS", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages or other liability, whether in an action of contract, tort or otherwise, arising from, out of or in connection with the software or the use or other dealings in the software.

*   **Risk of Data Loss:** Modifying EFI partitions and bootloaders carries a risk of rendering your system unbootable or causing data loss.
*   **Backup Required:** Always backup your data before performing system modifications.
*   **Not Official:** This is a community-maintained rescue kit and is not affiliated with Apple Inc. or the OpenCore project.
