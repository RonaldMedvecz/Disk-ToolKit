# Disk Toolkit

## About This Project

Disk Toolkit started as a straightforward internal need: our IT team needed a single, reliable way to securely wipe, clone, and image drives, without juggling a half dozen different command-line utilities or hoping everyone remembered the right `dd` flags. What began as a basic wipe script grew, iteration by iteration, into a full disk-management toolkit — because once the core wiping logic was solid, the next obvious question was always "can it also do this?"

This project was built in close collaboration with **Claude, Anthropic's AI assistant**. Every feature — from the parallelized secure-wipe engine, to size-adaptive disk cloning, to ISO capture/restore with destination space-checking, to the NTFS-corruption detection and repair workflow — was designed, implemented, and tested through an iterative back-and-forth: describing a real problem the team was hitting, having Claude propose and build a solution, verifying it against actual test disks and loop devices, and refining it when something didn't quite work as expected (including catching and fixing several real bugs along the way, like a partition-growth heuristic that could target the wrong partition, and a silent error-masking bug in the progress-dialog wrapper).

We're documenting that origin here deliberately, not as a disclaimer, but as context: this tool exists because an IT team had a recurring, practical problem, and AI-assisted development let us go from "we need this" to a tested, working solution quickly — without needing to be shell-scripting experts to get there. Every function in this codebase was exercised against real test disks before being trusted, and that verification process is part of what this project is.

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

This isn't a tool designed in the abstract — it's shaped by what actually went wrong the first few times.
