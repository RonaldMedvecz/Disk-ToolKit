# Disk Toolkit

## About This Project

Disk Toolkit started as a straightforward internal need: our IT team needed a single, reliable way to securely wipe, clone, and image drives, without juggling a half dozen different command-line utilities or hoping everyone remembered the right `dd` flags. What began as a basic wipe script grew, iteration by iteration, into a full disk-management toolkit — because once the core wiping logic was solid, the next obvious question was always "can it also do this?"

This project was developed with the assistance of Claude AI. Claude was used throughout the design, development, testing, and refinement process to help implement features, troubleshoot issues, and improve the overall reliability of the application. All features were iteratively tested and validated in real-world scenarios to ensure the toolkit functioned as intended and met the project's requirements.



## What It Does

Disk Toolkit is a single self-contained script with both a GUI (via `zenity`) and terminal interface, covering four core operations:

- **Wipe** — secure erasure via parallel random overwrite, zero-fill, or hardware secure-erase where the drive supports it
- **Clone** — disk-to-disk cloning that adapts to source/destination size differences, including automatic filesystem growth into extra destination space (or a guided handoff to GParted when automatic growth isn't safe to guess)
- **Capture Image** — create a compressed or raw backup image of a disk, with destination free-space checking *before* committing to the operation
- **Image from ISO** — restore a previously captured image back onto a drive

It also includes NTFS consistency checking with best-effort automatic repair, and falls back to clear, guided instructions (including opening GParted directly) when a problem needs manual attention or genuinely requires Windows `chkdsk`.

## Why It's Built This Way

Every design decision in this tool traces back to a real failure mode the team hit while using it:

- Parallelized wipe/clone/compression exist because a single-threaded pipeline couldn't saturate modern SSD/NVMe throughput
- The size-estimation logic for compressed images samples multiple points across the disk (not just the start) after an early version wildly underestimated file size by sampling only the empty front of a partition table
- The partition-growth logic stopped guessing "the last partition" after that heuristic expanded a recovery partition instead of the actual data partition on a real drive
- The NTFS repair workflow exists because `ntfsfix` alone doesn't fix the kind of cluster-accounting corruption GParted's own pre-check catches

