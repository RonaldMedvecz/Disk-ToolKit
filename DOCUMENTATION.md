# Disk Toolkit User Guide — Secure Wipe, Disk Clone, Image Capture, and Image Restore

This guide explains how to use the Disk Toolkit application to securely wipe drives, clone disks, capture disk images, and restore disk images.

Use this guide if you need to:

- Securely erase one or more hard drives or SSDs.
- Clone an existing drive to another drive.
- Create a backup image of an entire disk.
- Restore a previously captured disk image.
- Repair common NTFS filesystem issues encountered during cloning or restoring.
- Install or reinstall the Disk Toolkit application.
- Review the software dependencies required by Disk Toolkit.

> **Important:** These operations can permanently erase data. Always verify the selected source and destination drives before continuing.

---

## Table of Contents

- [Disk Toolkit Installation Files](#disk-toolkit-installation-files)
- [Software Dependencies](#software-dependencies)
- [1 - Launch Disk Toolkit](#1---launch-disk-toolkit)
- [2 - Select an Operation](#2---select-an-operation)
- [3 - Wipe Drive(s)](#3---wipe-drives)
- [4 - Clone Disk](#4---clone-disk)
- [5 - Capture Image](#5---capture-image)
- [6 - Restore an Image](#6---restore-an-image)
- [7 - NTFS Repair Workflow](#7---ntfs-repair-workflow)
- [8 - Installing or Reinstalling Disk Toolkit](#8---installing-or-reinstalling-disk-toolkit)
- [9 - Troubleshooting](#9---troubleshooting)
- [Other Useful Information](#other-useful-information)

---

## Disk Toolkit Installation Files

The approved Disk Toolkit installer and supporting files are located at:

```
\\gozer\installs\Disk Toolkit
```

<img width="1335" height="628" alt="Screenshot 2026-07-20 162456" src="https://github.com/user-attachments/assets/b6844296-4e97-412c-9186-52fad0104305" />


Use this location whenever Disk Toolkit needs to be installed or reinstalled.

Copy the current `.deb` installation file from this folder to the Linux computer before beginning the installation.

**Do not** download Disk Toolkit from an external website or use an unapproved copy.

## Software Dependencies

The software dependencies required by Disk Toolkit can be viewed in the `.deb` installation file located at:

```
\\gozer\installs\Disk Toolkit
```

Install the application using `apt` so the dependencies listed in the `.deb` package can be identified and installed automatically.

---

## 1 - Launch Disk Toolkit

Disk Toolkit can be opened in either of the following ways.

### 1.A - Open from the Desktop

1. Find the Disk Toolkit application on the desktop.
2. Double-click the application to launch it.
3. Enter the administrator password if prompted.

<img width="1611" height="904" alt="Screenshot 2026-07-20 162616" src="https://github.com/user-attachments/assets/c397c6bd-bba0-4511-bf10-3a66f0fbfc21" />


### 1.B - Open from Terminal

Open a Terminal window and run:

```bash
disk-toolkit
```

When prompted, enter administrator credentials.

Disk operations require elevated permissions, so a graphical authentication prompt or `sudo` prompt is expected.

---

## 2 - Select an Operation

After launching the application, choose one of the following options.

| Operation | Description |
|---|---|
| **Wipe Drive(s)** | Securely erase one or more drives |
| **Clone Disk** | Copy one drive to another |
| **Capture Image** | Create a compressed or raw disk image |
| **Image from ISO** | Restore a previously captured image |

Select the desired operation and click OK.

<img width="1031" height="644" alt="Screenshot 2026-07-20 162808" src="https://github.com/user-attachments/assets/794df70b-f82a-4bfb-bbcd-184d7a674c06" />


---

## 3 - Wipe Drive(s)

Use this option when a drive needs to be securely erased.

### 3.A - Select Drive(s)

1. Choose **Wipe Drive(s)**.
2. Select one or more drives from the checklist.
3. Verify that the selected drives are correct.

> **Warning:** This process permanently destroys all data on the selected drives.

Confirm the device name, storage capacity, and drive model before continuing.

<img width="1058" height="545" alt="Screenshot 2026-07-20 162927" src="https://github.com/user-attachments/assets/d4efb1f1-b674-47b2-9a5c-c17fd05792b7" />

### 3.B - Choose the Wipe Method

Choose one of the following options.

**Parallel Random Overwrite**
- Uses generated random-looking data.
- Provides the strongest software-based wipe option.
- Takes longer to complete.
- Recommended when a stronger overwrite is required.

**Parallel Zero Fill**
- Writes zeros across the drive.
- Fastest software-based wipe option.
- Recommended for most drive redeployment, testing, or reuse situations.

<img width="1066" height="413" alt="Screenshot 2026-07-20 163028" src="https://github.com/user-attachments/assets/66d02f84-4a8b-4759-8707-ac618204c699" />

### 3.C - Confirm the Wipe

To prevent accidental data loss:

1. Type `WIPE` exactly as shown.
2. Select OK.

The confirmation is case-sensitive.

<img width="856" height="274" alt="Screenshot 2026-07-20 163103" src="https://github.com/user-attachments/assets/490aaf8e-595a-4883-8063-87c0b5990d1b" />

### 3.D - Monitor Progress

During the wipe, the application displays:

- Overall progress
- Percentage complete
- Transfer speed
- Estimated remaining time
- Estimated completion time

Multiple selected drives are processed simultaneously.

<img width="669" height="181" alt="Screenshot 2026-07-20 163146" src="https://github.com/user-attachments/assets/dfb55073-eb15-4328-8792-b279e4f0ac1b" />

### 3.E - Completion

Once the wipe finishes, a completion notification appears for each selected drive.

Review the completion status before disconnecting or reusing the drive.

<img width="289" height="184" alt="Screenshot 2026-07-20 163450" src="https://github.com/user-attachments/assets/9f638c74-2492-45dc-9f9d-0b532f138afc" />

---

## 4 - Clone Disk

Use this option to duplicate one drive onto another.

### 4.A - Select the Source Drive

Choose the drive that contains the data to copy. This is the **source drive**.

Verify the source drive carefully before continuing.

<img width="770" height="455" alt="Screenshot 2026-07-20 163242" src="https://github.com/user-attachments/assets/c6179f2c-5d37-408f-aa28-8730b334e22f" />

### 4.B - Select the Destination Drive

Choose the drive that will receive the copied data. This is the **destination drive**.

> **Warning:** All existing data on the destination drive will be erased.

<img width="772" height="464" alt="Screenshot 2026-07-20 163315" src="https://github.com/user-attachments/assets/64423383-7d75-4966-bd4a-0775633ab1ba" />


### 4.C - Confirm the Clone

Type `CLONE` to begin the cloning process.

The confirmation is case-sensitive.

<img width="760" height="213" alt="Screenshot 2026-07-20 163522" src="https://github.com/user-attachments/assets/9f80b45a-4d95-4927-bb64-0ecce98ef2ff" />

### 4.D - Clone Process

Disk Toolkit automatically determines the appropriate cloning method.

**Destination Is Equal or Larger**

The application:
- Copies the entire drive.
- Copies the partition structure.
- Copies boot information.
- Automatically expands the filesystem when possible.

If multiple partitions exist and Disk Toolkit cannot safely determine which partition should be expanded, GParted opens automatically so the correct partition can be selected manually. This prevents the application from accidentally expanding an EFI, recovery, or reserved partition.

**Destination Is Smaller**

Before cloning, Disk Toolkit:
- Calculates the actual used space.
- Verifies that the used data will fit on the destination.
- Copies only used filesystem blocks when supported.
- Cancels the clone before changes are made if the data will not fit.

The destination drive does not need to match the full capacity of the source drive, but the used data and required partitions must fit.

### 4.E - Review with GParted

After every successful clone, GParted automatically opens. This allows you to:

- Verify the partition layout.
- Review unallocated space.
- Expand the correct partition if needed.
- Confirm the clone completed correctly.

Do not resize EFI, recovery, or reserved partitions unless specifically required.

<img width="684" height="477" alt="Screenshot 2026-07-20 163802" src="https://github.com/user-attachments/assets/3dca1d6a-bcab-4386-8236-53240ef2c94b" />

---

## 5 - Capture Image

Use this option to create a complete backup image of a disk.

### 5.A - Select the Source Disk

Choose the disk that will be captured.

Verify the device name, storage capacity, and model before continuing.

<img width="857" height="473" alt="Screenshot 2026-07-20 163838" src="https://github.com/user-attachments/assets/afac3d27-ec69-4931-9589-b39606329a83" />

### 5.B - Select Compression

Choose one of the following options.

**gzip – Recommended**
- Provides a balance of speed and compression.
- Uses less destination storage than an uncompressed image.
- Creates a file ending in `.img.gz`

**None**
- Creates an uncompressed image.
- May complete faster.
- Requires more destination storage.
- Creates a file ending in `.img`

<img width="857" height="331" alt="Screenshot 2026-07-20 163852" src="https://github.com/user-attachments/assets/a4e72618-8181-4c97-a465-c4601ecc5bbd" />

### 5.C - Choose a Save Location

Select one of the following options.

**Mounted Drive** — Choose an attached and mounted storage device.

**Browse** — Open the file browser and select a local or mounted folder.

**Remote Location** — Specify an SCP destination, for example:
```
user@host:/path
```
The remote computer must be reachable and configured to accept an SCP connection.

<img width="888" height="459" alt="Screenshot 2026-07-20 163920" src="https://github.com/user-attachments/assets/4d7357c9-0f21-4054-839d-db53a36a77ef" />

### 5.D - Storage Verification

Before imaging begins, Disk Toolkit:
- Estimates the expected image size.
- Checks the available destination storage.
- Stops immediately if insufficient storage is available.

This prevents the image process from failing after it has already been running for an extended period.

<img width="649" height="268" alt="Screenshot 2026-07-20 164021" src="https://github.com/user-attachments/assets/802f0745-3406-4dd9-a7b2-a447d31ef938" />

### 5.E - Monitor Progress

The application displays:
- Percentage complete
- Transfer speed
- Estimated remaining time
- Estimated completion time
- Current operation status

<img width="684" height="223" alt="Screenshot 2026-07-20 164044" src="https://github.com/user-attachments/assets/2bb91ca6-1152-4c68-abca-c4b4e88fe32f" />

### 5.F - Completed Files

Upon completion, the following files are created:

| File | Purpose |
|---|---|
| `.img` or `.img.gz` | The image itself |
| `.sha256` | Checksum, used to verify the image has not been corrupted |
| `.size` | Records the original disk size, used during restoration |

Keep the image, checksum file, and size file together.

<img width="741" height="461" alt="Screenshot 2026-07-21 084404" src="https://github.com/user-attachments/assets/45e8aae1-e56c-4446-a992-140e4309760d" />

---

## 6 - Restore an Image

Use this option to restore a previously captured image.

### 6.A - Select the Image

Browse to the desired `.img` or `.img.gz` file.

When available, keep the matching `.sha256` and `.size` files in the same folder as the image.

<img width="696" height="278" alt="Screenshot 2026-07-21 084434" src="https://github.com/user-attachments/assets/fba5cd2d-d2cd-4e1f-a79a-b45d72d5a912" />

### 6.B - Select the Destination Drive

Choose the drive that will receive the image.

> **Warning:** All existing data on the destination drive will be erased.

Verify the device name, capacity, and model before continuing.

<img width="829" height="438" alt="Screenshot 2026-07-21 084451" src="https://github.com/user-attachments/assets/40d2144e-521a-4c91-89c8-a3e3def064f1" />

### 6.C - Confirm the Restore

Type `RESTORE` to continue.

The confirmation is case-sensitive.

<img width="848" height="186" alt="Screenshot 2026-07-21 084530" src="https://github.com/user-attachments/assets/4c2a130d-12ee-448b-9399-bf909ece67ea" />

### 6.D - Image Verification

Before restoring, Disk Toolkit verifies:
- Image size
- Original disk size
- Destination drive capacity
- Supporting metadata when available

If the image is larger than the destination drive, the restore will not begin.

<img width="627" height="254" alt="Screenshot 2026-07-21 084605" src="https://github.com/user-attachments/assets/8d4c9d72-f3c8-4aef-9440-1eb0f6850ef2" />

### 6.E - Monitor the Restore

During the restore, the application displays:
- Percentage complete
- Transfer speed
- Estimated remaining time
- Estimated completion time
- Current operation status

Before writing anything, the tool also verifies the image file's own integrity (a `gzip` check for `.img.gz` files), shown below:

<img width="655" height="167" alt="Screenshot 2026-07-21 084622" src="https://github.com/user-attachments/assets/01c92557-6f17-4291-a29d-be05a7cbc57c" />

### 6.F - Filesystem Expansion

If restoring to a larger drive, Disk Toolkit automatically attempts to expand supported filesystems.

If manual partition selection is required, GParted opens automatically after the restore. Use GParted to verify the restored partition layout and expand the correct partition if necessary.

---

## 7 - NTFS Repair Workflow

If an NTFS filesystem contains structural inconsistencies during a clone or restore, Disk Toolkit automatically performs the following steps.

This is the kind of failure GParted itself will refuse to proceed past — for example:


### 7.A - Automatic Repair

Disk Toolkit:

1. Runs `ntfsfix`.
2. Verifies the filesystem independently.
3. If necessary and available, asks permission to run `ntfsck`.
4. Performs another independent filesystem verification.

Disk Toolkit does not rely only on the repair command's success message. It checks the filesystem again after each repair attempt.

### 7.B - Windows Repair Required

If the filesystem remains inconsistent, Disk Toolkit recommends repairing the drive from Windows.

1. Connect the drive to a Windows computer.
2. Disable Windows Fast Startup.
3. Open Command Prompt as an administrator.
4. Run `chkdsk X: /f` (replace `X:` with the correct drive letter).
5. Restart Windows.
6. Open an elevated Command Prompt again.
7. Run the same command a second time.
8. Return the drive to the Disk Toolkit computer.
9. Retry the Clone or Restore operation.

GParted may still open so additional partition work can be completed if necessary.

---

## 8 - Installing or Reinstalling Disk Toolkit

Use this section when Disk Toolkit needs to be installed, reinstalled, or repaired.

### 8.A - Locate the Installer

Open the following network location:
```
\\gozer\installs\Disk Toolkit
```
Locate the current Disk Toolkit `.deb` installation package, for example `disk-toolkit_1.0.3.deb`. The version number may be different if a newer approved package is available.

Copy the installer to the Linux computer or another accessible location.

### 8.B - Install the Application

Open a Terminal window, browse to the folder containing the `.deb` file, and run:

```bash
sudo apt install ./disk-toolkit_1.0.3.deb
```

Replace the filename with the current approved version if necessary.

Using `apt` allows the operating system to read the dependency information contained in the `.deb` package and install the required supporting software.

### 8.C - Repair Missing Dependencies

If dependencies are missing or the installation is incomplete, run:

```bash
sudo apt install -f
```

After the repair completes, run the Disk Toolkit installation command again if necessary.

### 8.D - Review Software Dependencies

The software dependencies required by Disk Toolkit can be viewed within the `.deb` installation file located at:
```
\\gozer\installs\Disk Toolkit
```
The `.deb` package contains the dependency information used by `apt` during installation. A separate software dependency list is not maintained in this article because dependency requirements may change between application versions.

### 8.E - Avoid Installing with DPKG Alone

Avoid installing with:

```bash
sudo dpkg -i disk-toolkit_1.0.3.deb
```

unless dependency installation will be handled separately. Using `dpkg -i` alone may leave Disk Toolkit partially installed if required dependencies are missing.

This is what a successful install looks like from the Software Center / App Center view:


---

## 9 - Troubleshooting

### 9.A - Disk Toolkit Is Installed but Will Not Launch

Run:
```bash
sudo apt install -f
```
Then reinstall the approved package from `\\gozer\installs\Disk Toolkit` using:
```bash
sudo apt install ./disk-toolkit_1.0.3.deb
```
Replace the filename if a newer approved version is available.

### 9.B - GParted or Another Supporting Tool Is Missing

The required supporting software should be installed automatically when the `.deb` file is installed using `apt`.

1. Obtain the current installer from `\\gozer\installs\Disk Toolkit`.
2. Install it using `sudo apt install ./disk-toolkit_1.0.3.deb`.
3. If the installation remains incomplete, run `sudo apt install -f`.

The required software dependencies can be viewed in the `.deb` installation file.

### 9.C - Image or Installer File Shows 0 Bytes

A zero-byte file usually indicates that the transfer did not finish before the storage device was disconnected.

1. Delete the incomplete file.
2. Copy the file again.
3. Wait for the copy operation to complete.
4. Open a Terminal window.
5. Run `sync`.
6. Wait for the command to complete before ejecting the storage device.

### 9.D - Permission Denied

Disk Toolkit requires administrator privileges. Launch the application normally and approve the authentication prompt, or from a Terminal run `disk-toolkit` and enter the administrator password when prompted.

### 9.E - Destination Drive Does Not Appear

1. Confirm the drive is physically connected.
2. Disconnect and reconnect the drive.
3. Try another USB port, cable, dock, or adapter.
4. Open a Terminal window and run `lsblk`.
5. Confirm the operating system detects the drive.
6. Close and reopen Disk Toolkit after connecting the drive.

### 9.F - Clone or Restore Cannot Expand the Filesystem

Possible causes include:
- The disk contains multiple partitions.
- The final partition is not the main data partition.
- The filesystem is not supported for automatic expansion.
- The filesystem contains errors.
- An NTFS volume was not shut down correctly in Windows.
- Windows Fast Startup is still enabled.

Allow GParted to open and review the partition layout. Do not expand an EFI, recovery, or reserved partition unless specifically required.

---

## Other Useful Information

### Manual Secure Wipe Commands

These commands perform similar wipe operations to the application and should only be used when Disk Toolkit is unavailable.

> **Warning:** These commands permanently erase data.

**Identify the Correct Drive**
```bash
lsblk
```
Always verify the target drive before continuing. Example device names include `/dev/sdb`, `/dev/sdc`, `/dev/nvme1n1`. Never assume `/dev/sda` is the intended target.

**Zero-Fill Wipe**
```bash
sudo dd if=/dev/zero of=/dev/sdX bs=64M status=progress conv=fsync
```

**Random-Data Wipe**
```bash
sudo sh -c 'openssl enc -aes-256-ctr -K $(openssl rand -hex 32) -iv $(openssl rand -hex 16) </dev/zero | dd of=/dev/sdX bs=64M status=progress conv=fsync'
```

Replace `/dev/sdX` in both commands with the actual target device name confirmed via `lsblk`.

### Additional Notes

- Obtain the approved Disk Toolkit installer from `\\gozer\installs\Disk Toolkit`.
- The required software dependencies can be viewed in the `.deb` installation file stored in the same folder.
- Install the `.deb` file using `apt` so required dependencies are installed automatically.
- Always verify the correct source and destination drives before starting an operation.
- Wipe, Clone, and Restore operations cannot be undone.
- GParted automatically opens after successful Clone and Restore operations to allow partition verification and resizing.
- Image Capture automatically creates checksum (`.sha256`) and size (`.size`) files.
- Keep the image, checksum, and size files together for future verification and restoration.
- Disk Toolkit checks destination capacity before starting Clone, Capture, or Restore operations.
- If NTFS repair cannot be completed automatically, repair the filesystem in Windows before attempting another Clone or Restore.
- TeamViewer is installed on the Disk Toolkit computer. To remotely monitor the progress of a Wipe, Clone, Capture Image, or Restore operation, connect to the computer using TeamViewer.
