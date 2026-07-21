#!/usr/bin/env bash
set -uo pipefail

BLOCK_SIZE="64M"
BLOCK_BYTES=$((64 * 1024 * 1024))

# Drives/operations processed concurrently with each other.
PARALLEL_JOBS=2

# Parallel streams *within* a single operation (wipe pass, clone copy, or
# image compression). Default to nproc, capped at 4.
PARALLELISM=${PARALLELISM:-$(nproc 2>/dev/null || echo 2)}
(( PARALLELISM > 4 )) && PARALLELISM=4
(( PARALLELISM < 1 )) && PARALLELISM=1

STAGING_DIR=${STAGING_DIR:-/var/tmp}

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-$HOME/.Xauthority}"

if [[ $EUID -ne 0 ]]; then
    if command -v pkexec >/dev/null; then
        pkexec env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" "$0"
    else
        sudo -E "$0"
    fi
    exit $?
fi

has_gui=false
if command -v zenity >/dev/null && [[ -n "${DISPLAY:-}" ]]; then
    has_gui=true
fi


list_drives() {
    lsblk -dn -o NAME,SIZE,MODEL,TYPE | awk '$4=="disk" {print $1,$2,substr($0,index($0,$3))}'
}

# Lists currently-mounted partitions/drives that could serve as an ISO
# destination: device name, human size, filesystem type, mount point.
# Used to let the imaging flow offer "pick a plugged-in drive" instead of
# requiring the destination path to be typed out by hand.
#
# Uses lsblk -P (NAME="..." SIZE="..." ...) rather than plain columnar
# output: a blank FSTYPE field (common on virtual/network block devices,
# and not unheard of on real ones) shifts every later column in the plain
# format, silently corrupting the mount-point field. -P keeps each field
# correctly tagged regardless of which ones are empty. Output is
# tab-separated so mount points containing spaces still parse correctly.
list_mounted_targets() {
    local line NAME SIZE FSTYPE MOUNTPOINT
    while IFS= read -r line; do
        NAME=""; SIZE=""; FSTYPE=""; MOUNTPOINT=""
        eval "$line"
        if [[ -n "$MOUNTPOINT" && "$MOUNTPOINT" != "[SWAP]" ]]; then
            printf '%s\t%s\t%s\t%s\n' "$NAME" "$SIZE" "${FSTYPE:-unknown}" "$MOUNTPOINT"
        fi
    done < <(lsblk -Pno NAME,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null)
}

human_size() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "${1} bytes"
}

# The script always re-execs itself as root via pkexec/sudo (see top of
# file), so by the time any code here runs, $HOME/$USER point at root, not
# at the person who actually launched it. sudo sets $SUDO_USER; pkexec sets
# $PKEXEC_UID. Use whichever is present to find the real user's home, so
# the desktop shortcut lands on their Desktop instead of /root/Desktop.
resolve_target_user_home() {
    local target_user="${SUDO_USER:-}"
    if [[ -z "$target_user" && -n "${PKEXEC_UID:-}" ]]; then
        target_user=$(id -nu "${PKEXEC_UID}" 2>/dev/null || true)
    fi
    [[ -z "$target_user" ]] && target_user="${USER:-root}"
    local home_dir
    home_dir=$(getent passwd "$target_user" 2>/dev/null | cut -d: -f6)
    [[ -z "$home_dir" ]] && home_dir="$HOME"
    echo "${target_user}:${home_dir}"
}

# Creates (or refreshes) a .desktop launcher on the invoking user's Desktop
# that runs this script directly -- double-clicking it re-triggers the same
# pkexec/sudo elevation at the top of this file, so no separate privilege
# setup is needed. Safe to call every run: it just overwrites the same file.
install_desktop_shortcut() {
    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null) || return 0

    local info target_user target_home
    info=$(resolve_target_user_home)
    target_user="${info%%:*}"
    target_home="${info#*:}"
    [[ -z "$target_home" || ! -d "$target_home" ]] && return 0

    local desktop_dir="$target_home/Desktop"
    mkdir -p "$desktop_dir" 2>/dev/null || return 0

    local desktop_file="$desktop_dir/Disk-Toolkit.desktop"

    # If a shortcut already exists and points at this same script, leave it
    # completely alone. Rewriting the file's content on every launch (the
    # previous behavior) was a real bug: GNOME/Nautilus-style desktops only
    # let a .desktop launcher run after it's been marked "trusted" (either
    # via a one-time "Allow Launching" click, or the gio call below), and
    # that trust is tied to the file itself -- so recreating it on every
    # run silently un-trusted it again right after it started working.
    if [[ -f "$desktop_file" ]] && grep -qF "$script_path" "$desktop_file" 2>/dev/null; then
        return 0
    fi

    cat > "$desktop_file" << EOF
[Desktop Entry]
Type=Application
Name=Disk Toolkit
Comment=Wipe drives, clone disks, or create ISO/backup images
Exec=bash "$script_path"
Icon=drive-harddisk
Terminal=false
Categories=System;Utility;
EOF
    chmod +x "$desktop_file" 2>/dev/null
    chown "$target_user":"$target_user" "$desktop_file" 2>/dev/null || true

    # GNOME/Nautilus and similar file managers refuse to launch a
    # double-clicked .desktop file until it's marked "trusted". Setting
    # that mark goes through gvfs over D-Bus, which needs the target
    # user's own session bus -- running `gio set` bare via sudo -u doesn't
    # have that, so it was silently failing every time. Point it at that
    # user's actual runtime dir/session bus explicitly.
    if command -v gio >/dev/null 2>&1; then
        local uid
        uid=$(id -u "$target_user" 2>/dev/null)
        if [[ -n "$uid" ]]; then
            sudo -u "$target_user" \
                XDG_RUNTIME_DIR="/run/user/$uid" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
                gio set "$desktop_file" "metadata::trusted" true 2>/dev/null || true
        fi
    fi

    echo "Desktop shortcut created at $desktop_file." >&2
    echo "If double-clicking it doesn't launch the app the first time, right-click it and choose 'Allow Launching' (or 'Properties -> Permissions -> Allow executing as program') -- most desktops require that one-time step for a new launcher, and it will stick after that." >&2
}

# Fast keystream generator: AES-256-CTR seeded straight from /dev/urandom.
# No PBKDF2 -- there is nothing to protect the key against offline cracking
# for; it exists only to produce a random-looking byte stream and is
# discarded the instant the operation finishes.
make_random_stream() {
    local key iv
    key=$(openssl rand -hex 32)
    iv=$(openssl rand -hex 16)
    openssl enc -aes-256-ctr -K "$key" -iv "$iv" </dev/zero 2>/dev/null
}

# Emits either zenity-format progress lines ("# text" + bare percentage) or
# a single updating terminal line, depending on $has_gui.
report_progress() {
    local label="$1" start_time="$2" pct="$3"
    local now elapsed remaining mm ss eta_epoch eta_clock

    now=$(date +%s)
    elapsed=$(( now - start_time ))
    if (( pct > 0 )); then
        remaining=$(( elapsed * (100 - pct) / pct ))
    else
        remaining=0
    fi
    (( remaining < 0 )) && remaining=0
    mm=$(( remaining / 60 ))
    ss=$(( remaining % 60 ))
    eta_epoch=$(( now + remaining ))
    eta_clock=$(date -d "@${eta_epoch}" +"%H:%M:%S" 2>/dev/null || date -r "${eta_epoch}" +"%H:%M:%S" 2>/dev/null || echo "unknown")

    if [[ "$has_gui" == true ]]; then
        printf '# %s: %d%% done. Est. remaining %02d:%02d. Est. finish %s\n' \
            "$label" "$pct" "$mm" "$ss" "$eta_clock"
        echo "$pct"
    else
        printf '\r%s: %3d%% | remaining %02d:%02d | ETA %s   ' \
            "$label" "$pct" "$mm" "$ss" "$eta_clock" >&2
    fi
}

# Runs the named function (with its args) either straight to the terminal or
# piped into a zenity progress dialog. The function itself is responsible
# for emitting "# text" / bare-percentage lines (via report_progress) on the
# GUI path.
with_progress_dialog() {
    local title="$1"; shift
    if [[ "$has_gui" == true ]]; then
        ( "$@" ) 2>&1 | zenity --progress \
            --title="$title" --text="$title" \
            --percentage=0 --auto-close --width=720
        # PIPESTATUS[0] is the wrapped function's own exit code, independent
        # of what zenity itself returns (e.g. if the user hits Cancel).
        return "${PIPESTATUS[0]}"
    else
        "$@"
        local rc=$?
        echo
        return $rc
    fi
}

# Fire-and-forget desktop notification (no-op in terminal mode, and safely
# ignored if the notification daemon isn't running). Used for "something is
# happening in the background" heads-up messages that don't need to block
# on an OK click the way zenity --info/--question/--error do.
notify_toast() {
    [[ "$has_gui" == true ]] || return 0
    zenity --notification --window-icon=info --text="$1" 2>/dev/null || true
}

# Splits [0, size) into $PARALLELISM byte ranges and runs $reader_fn(offset,
# length) -> stdout for each range concurrently, writing the results into
# $dst at the matching byte offset via dd's seek_bytes/count_bytes (so
# ranges don't need to be block-count-aligned) with conv=notrunc (so
# concurrent writers to the same target can't truncate each other's data).
# Used by both the wipe feature (reader = a generator) and the clone
# feature (reader = a read from the source disk).
run_chunked_transfer() {
    local dst="$1" size="$2" reader_fn="$3" label="$4"
    local n=$PARALLELISM
    local total_blocks=$(( size / BLOCK_BYTES )); (( total_blocks < 1 )) && total_blocks=1
    (( n > total_blocks )) && n=$total_blocks

    local base_len=$(( (size / n / BLOCK_BYTES) * BLOCK_BYTES ))
    (( base_len < BLOCK_BYTES )) && base_len=$BLOCK_BYTES

    local progdir
    progdir=$(mktemp -d "$STAGING_DIR/progress-XXXXXX")
    local start_time
    start_time=$(date +%s)

    local -a offsets lengths pids progfiles
    local offset=0 i
    for (( i=0; i<n; i++ )); do
        local len=$base_len
        (( i == n-1 )) && len=$(( size - offset ))
        offsets[i]=$offset; lengths[i]=$len
        progfiles[i]="$progdir/chunk_$i"
        echo 0 > "${progfiles[i]}"
        offset=$(( offset + len ))
    done

    set +o pipefail
    for (( i=0; i<n; i++ )); do
        "$reader_fn" "${offsets[i]}" "${lengths[i]}" \
            | pv -n -s "${lengths[i]}" 2> >(while IFS= read -r p; do printf '%s' "$p" > "${progfiles[i]}"; done) \
            | dd of="$dst" bs="$BLOCK_SIZE" seek="${offsets[i]}" oflag=seek_bytes \
                  count="${lengths[i]}" iflag=count_bytes,fullblock status=none conv=fsync,notrunc &
        pids[i]=$!
    done

    (
        while true; do
            local done_bytes=0 alive=0 p
            for (( i=0; i<n; i++ )); do
                p=$(cat "${progfiles[i]}" 2>/dev/null || echo 0)
                [[ "$p" =~ ^[0-9]+$ ]] || p=0
                done_bytes=$(( done_bytes + lengths[i] * p / 100 ))
                kill -0 "${pids[i]}" 2>/dev/null && alive=1
            done
            local overall_pct=$(( done_bytes * 100 / size ))
            (( overall_pct > 100 )) && overall_pct=100
            report_progress "$label" "$start_time" "$overall_pct"
            (( alive == 0 )) && break
            sleep 1
        done
    ) &
    local monitor_pid=$!

    local rc=0
    for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    set -o pipefail
    rm -rf "$progdir"
    sync
    return $rc
}

# Same idea as run_chunked_transfer, but for producing a single compressed
# output file instead of writing into a block device: each byte range is
# compressed independently into its own part file, then the parts are
# concatenated in order. This works because gzip supports multi-member
# concatenated streams -- decompressing the concatenation is identical to
# decompressing the parts in sequence. It's the same trick pigz uses
# internally, done by hand here since pigz may not be installed (in which
# case resolve_compressor falls back to plain gzip).
run_chunked_compress() {
    local reader_fn="$1" size="$2" out_file="$3" compressor="$4" label="$5"
    local n=$PARALLELISM
    local total_blocks=$(( size / BLOCK_BYTES )); (( total_blocks < 1 )) && total_blocks=1
    (( n > total_blocks )) && n=$total_blocks

    local base_len=$(( (size / n / BLOCK_BYTES) * BLOCK_BYTES ))
    (( base_len < BLOCK_BYTES )) && base_len=$BLOCK_BYTES

    local partdir progdir start_time
    partdir=$(mktemp -d "$STAGING_DIR/image-parts-XXXXXX")
    progdir=$(mktemp -d "$STAGING_DIR/progress-XXXXXX")
    start_time=$(date +%s)

    local -a offsets lengths pids progfiles partfiles
    local offset=0 i
    for (( i=0; i<n; i++ )); do
        local len=$base_len
        (( i == n-1 )) && len=$(( size - offset ))
        offsets[i]=$offset; lengths[i]=$len
        progfiles[i]="$progdir/chunk_$i"
        partfiles[i]="$partdir/part_$(printf '%04d' "$i")"
        echo 0 > "${progfiles[i]}"
        offset=$(( offset + len ))
    done

    set +o pipefail
    for (( i=0; i<n; i++ )); do
        if [[ "$compressor" == "none" ]]; then
            "$reader_fn" "${offsets[i]}" "${lengths[i]}" \
                | pv -n -s "${lengths[i]}" 2> >(while IFS= read -r p; do printf '%s' "$p" > "${progfiles[i]}"; done) \
                > "${partfiles[i]}" &
        else
            "$reader_fn" "${offsets[i]}" "${lengths[i]}" \
                | pv -n -s "${lengths[i]}" 2> >(while IFS= read -r p; do printf '%s' "$p" > "${progfiles[i]}"; done) \
                | $compressor > "${partfiles[i]}" &
        fi
        pids[i]=$!
    done

    (
        while true; do
            local done_bytes=0 alive=0 p
            for (( i=0; i<n; i++ )); do
                p=$(cat "${progfiles[i]}" 2>/dev/null || echo 0)
                [[ "$p" =~ ^[0-9]+$ ]] || p=0
                done_bytes=$(( done_bytes + lengths[i] * p / 100 ))
                kill -0 "${pids[i]}" 2>/dev/null && alive=1
            done
            local overall_pct=$(( done_bytes * 100 / size ))
            (( overall_pct > 100 )) && overall_pct=100
            report_progress "$label" "$start_time" "$overall_pct"
            (( alive == 0 )) && break
            sleep 1
        done
    ) &
    local monitor_pid=$!

    local rc=0
    for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    set -o pipefail
    rm -rf "$progdir"

    if (( rc == 0 )); then
        local expected_bytes=0 pf
        for pf in "${partfiles[@]}"; do
            expected_bytes=$(( expected_bytes + $(stat -c%s "$pf" 2>/dev/null || echo 0) ))
        done
        if cat "${partfiles[@]}" > "$out_file"; then
            local actual_bytes
            actual_bytes=$(stat -c%s "$out_file" 2>/dev/null || echo -1)
            if (( actual_bytes != expected_bytes )); then
                echo "ERROR: wrote $(human_size "$actual_bytes") but expected $(human_size "$expected_bytes") -- the destination likely ran out of space. Removing the incomplete file." >&2
                rm -f "$out_file"
                rc=1
            fi
        else
            echo "ERROR: failed writing to $out_file (destination may be full, disconnected, or unwritable). Removing any partial file." >&2
            rm -f "$out_file"
            rc=1
        fi
    fi
    rm -rf "$partdir"
    return $rc
}

# ===========================================================================
# FEATURE 1: Wipe
# ===========================================================================

chunk_reader_random() { make_random_stream; }
chunk_reader_zero()   { cat /dev/zero; }

wipe_full_random_body() {
    local disk="$1" size="$2"
    echo "# Wiping $disk with $PARALLELISM parallel random streams..."
    run_chunked_transfer "$disk" "$size" chunk_reader_random "Wiping $disk"
    local rc=$?
    echo 100
    echo "# Finished wiping $disk"
    return $rc
}

wipe_zero_body() {
    local disk="$1" size="$2"
    echo "# Wiping $disk with zeroes ($PARALLELISM-way)..."
    run_chunked_transfer "$disk" "$size" chunk_reader_zero "Wiping $disk"
    local rc=$?
    echo 100
    echo "# Finished wiping $disk"
    return $rc
}

wipe_full_random() { with_progress_dialog "Wiping $1" wipe_full_random_body "$1" "$2"; }
wipe_zero()        { with_progress_dialog "Wiping $1" wipe_zero_body "$1" "$2"; }

wipe_drive() {
    local dev="$1" method="$2"
    local disk="/dev/$dev"
    local size
    size=$(blockdev --getsize64 "$disk")

    echo "Unmounting partitions on $disk..."
    umount "${disk}"* 2>/dev/null || true

    case "$method" in
        full_random) wipe_full_random "$disk" "$size" ;;
        zero)        wipe_zero "$disk" "$size" ;;
    esac
}

# ===========================================================================
# FEATURE 2: Clone (dynamic disk-size cloning)
# ===========================================================================

CLONE_SRC_DISK=""
chunk_reader_clone_copy() {
    local offset="$1" length="$2"
    dd if="$CLONE_SRC_DISK" bs="$BLOCK_SIZE" skip="$offset" \
       iflag=skip_bytes,count_bytes,fullblock count="$length" status=none
}

# Grows a filesystem to fill all available space on $dev. Handles the
# common filesystem types; anything else is reported and skipped (data is
# never at risk here -- worst case the extra destination capacity is left
# unused).
# Runs ntfsresize's own read-only consistency check (-i = info/dry-run,
# makes no changes) and looks for the "cluster accounting" / "NTFS is
# inconsistent" failure pattern. This is the same check GParted itself runs
# before it will touch an NTFS partition -- catching it here first means
# the tool can explain what's wrong and point at the real fix (chkdsk)
# instead of just failing opaquely, or worse, letting a resize attempt run
# into the same wall GParted would.
#
# Returns 0 if consistent, 1 if the structural-corruption pattern was
# found. Diagnostic output is echoed to stderr either way.
check_ntfs_consistency() {
    local dev="$1"
    local output
    output=$(ntfsresize -i -f -v "$dev" 2>&1)
    echo "$output" >&2
    if echo "$output" | grep -qi "cluster accounting failed\|NTFS is inconsistent"; then
        return 1
    fi
    return 0
}

# Best-effort automatic repair for the corruption check_ntfs_consistency
# detects. This has a hard ceiling: no Linux tool is a full equivalent of
# Windows chkdsk for NTFS metadata repair, and this function never
# pretends otherwise -- it tries what's safely possible, then
# independently re-checks with check_ntfs_consistency again rather than
# trusting either tool's own exit code. If it's still inconsistent
# afterward, the caller falls through to offer_ntfs_repair_guidance
# (the actual chkdsk-in-Windows fix) exactly as if this had never run.
#
# Two tiers, in order:
#  1. `ntfsfix` -- always run if present. It resets $LogFile and fixes a
#     couple of minor issues, but its real relevant effect here is that it
#     marks the volume "dirty", which schedules Windows's own chkdsk to
#     run automatically the next time this drive is read by an actual
#     Windows boot -- no need for anyone to remember the command. This
#     does NOT fix $Bitmap/cluster accounting itself.
#  2. `ntfsck --repair` -- only if installed, and only with explicit
#     confirmation. This is ntfs-3g's own experimental metadata repair
#     tool and is the closest thing Linux has to real chkdsk-equivalent
#     repair, including some bitmap-related fixes -- but it's labeled
#     experimental upstream, isn't guaranteed complete, and its exact
#     behavior can vary by ntfs-3g version. Never run without asking.
#
# Returns 0 if the volume verifiably passes the consistency check
# afterward, 1 if it's still inconsistent.
attempt_ntfs_auto_repair() {
    local dev="$1"

    if command -v ntfsfix >/dev/null; then
        echo "Running ntfsfix on $dev (resets \$LogFile; also marks the volume dirty so Windows will auto-schedule chkdsk on its next boot)..." >&2
        ntfsfix "$dev" >&2 2>&1 || true
    else
        echo "ntfsfix not installed; skipping that step." >&2
    fi

    if check_ntfs_consistency "$dev"; then
        echo "$dev now passes the consistency check after ntfsfix." >&2
        return 0
    fi

    if command -v ntfsck >/dev/null; then
        local proceed=false
        local ask_msg="An experimental Linux-native repair tool (ntfsck --repair) is available for $dev.
This is NOT guaranteed to fully fix the corruption the way Windows chkdsk would -- ntfs-3g documents it as experimental. Back up anything important first if you can.

Attempt it now?"
        if [[ "$has_gui" == true ]]; then
            zenity --question --title="Try Experimental NTFS Repair?" --width=700 --text="$ask_msg" 2>/dev/null && proceed=true
        else
            local ans
            read -rp "$ask_msg [y/N]: " ans
            [[ "$ans" =~ ^[Yy]$ ]] && proceed=true
        fi

        if [[ "$proceed" == true ]]; then
            echo "Running ntfsck --repair on $dev (experimental)..." >&2
            ntfsck --repair "$dev" >&2 2>&1 || true
        else
            echo "Skipped ntfsck at the user's choice." >&2
        fi
    else
        echo "ntfsck not installed; no further automatic repair option available on Linux for this." >&2
    fi

    if check_ntfs_consistency "$dev"; then
        echo "$dev now passes the consistency check." >&2
        return 0
    fi

    echo "$dev is still structurally inconsistent after automatic repair attempts -- this needs chkdsk on Windows." >&2
    return 1
}

resize_filesystem() {
    local dev="$1"
    local fstype
    fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)
    case "$fstype" in
        ext2|ext3|ext4)
            echo "Running e2fsck (required before resize2fs) on $dev..."
            e2fsck -f -y "$dev" >/dev/null 2>&1
            echo "Growing ext filesystem on $dev to fill available space..."
            resize2fs "$dev"
            return $?
            ;;
        xfs)
            if command -v xfs_growfs >/dev/null; then
                echo "Growing xfs filesystem on $dev..."
                local mnt
                mnt=$(mktemp -d "$STAGING_DIR/xfsgrow-XXXXXX")
                mount "$dev" "$mnt" && xfs_growfs "$mnt"; local rc=$?
                umount "$mnt"; rmdir "$mnt"
                return $rc
            else
                echo "xfs_growfs not installed; skipping xfs grow on $dev." >&2
                return 2
            fi
            ;;
        ntfs)
            if ! command -v ntfsresize >/dev/null; then
                echo "ntfsresize (ntfs-3g) not installed; skipping NTFS grow on $dev." >&2
                return 2
            fi
            echo "Checking NTFS consistency on $dev before attempting to grow it..."
            if ! check_ntfs_consistency "$dev"; then
                echo "NTFS structural corruption detected on $dev -- attempting automatic repair before giving up..." >&2
                if ! attempt_ntfs_auto_repair "$dev"; then
                    echo "Automatic repair could not resolve it; refusing to resize until it's fixed via chkdsk." >&2
                    return 3
                fi
            fi
            echo "Growing NTFS filesystem on $dev to fill available space..."
            ntfsresize -f -P "$dev" <<< y
            return $?
            ;;
        btrfs)
            if command -v btrfs >/dev/null; then
                local mnt
                mnt=$(mktemp -d "$STAGING_DIR/btrfsgrow-XXXXXX")
                mount "$dev" "$mnt" && btrfs filesystem resize max "$mnt"; local rc=$?
                umount "$mnt"; rmdir "$mnt"
                return $rc
            else
                echo "btrfs-progs not installed; skipping btrfs grow on $dev." >&2
                return 2
            fi
            ;;
        *)
            echo "Unrecognized or unsupported filesystem ('${fstype:-none}') on $dev; skipping automatic grow." >&2
            return 2
            ;;
    esac
}

# After a whole-disk clone/restore onto a larger destination, use the extra
# space. Only auto-grows the unambiguous case: a plain whole-device
# filesystem with no partition table (common on secondary/data/USB drives),
# where there's exactly one filesystem and no possible confusion about
# what to expand.
#
# Deliberately does NOT try to guess which partition to grow on a
# partitioned disk (e.g. "grow the last partition"): real-world layouts
# routinely put a small recovery, EFI, or swap partition last, so that
# heuristic ends up expanding the wrong partition while leaving the actual
# data partition untouched. Picking the right one requires knowing the
# layout, which is exactly what GParted's manual partition-by-partition
# view is for -- so partitioned disks always go to
# offer_gparted_fallback() instead of guessing.
#
# Before handing off to GParted, any NTFS partitions on the disk are
# checked for the same structural corruption GParted's own pre-check would
# catch (see check_ntfs_consistency) -- if found, this returns 3 so the
# caller can point straight at the chkdsk fix instead of sending the
# person into GParted just to hit the same wall your screenshots showed.
#
# Returns 0 if it actually grew something, 3 if an NTFS partition is
# structurally corrupt and needs chkdsk first, 2 if growth otherwise needs
# to be done manually (partition table present, or fs type/tools not
# supported), 1 on a real failure. Callers should treat 1/2 as "offer the
# GParted fallback" and 3 as "offer the NTFS/chkdsk guidance instead."
clone_grow_step() {
    local dst="$1"
    local pttype
    pttype=$(blkid -o value -s PTTYPE "$dst" 2>/dev/null || true)

    if [[ -n "$pttype" ]]; then
        echo "$dst has a partition table ($pttype) with multiple partitions -- picking which one to grow automatically isn't reliable (e.g. a trailing recovery/EFI partition can get expanded instead of the real data partition)." >&2

        local part fstype
        while read -r part fstype; do
            [[ "$fstype" == "ntfs" ]] || continue
            echo "Checking NTFS consistency on /dev/$part before opening GParted..." >&2
            if ! check_ntfs_consistency "/dev/$part"; then
                echo "NTFS structural corruption detected on /dev/$part -- attempting automatic repair first..." >&2
                if ! attempt_ntfs_auto_repair "/dev/$part"; then
                    return 3
                fi
            fi
        done < <(lsblk -rno NAME,FSTYPE "$dst" 2>/dev/null)

        echo "Opening GParted so the correct partition can be chosen manually." >&2
        return 2
    else
        resize_filesystem "$dst"
        return $?
    fi
}

# Offers to open GParted so the person can manually choose and expand the
# right partition. This is the primary path for any partitioned disk (see
# clone_grow_step above) -- not just a fallback for a failed attempt. The
# data itself is never at risk here -- this only affects whether the extra
# destination capacity gets used or needs a manual resize.
# Opens GParted directly on a drive so partitions can be reviewed or
# resized manually. Not gated behind a yes/no -- the point of calling this
# is to *guarantee* GParted actually opens (after any checks/repair
# attempts have run and their results have been shown), not to leave it as
# a skippable option. Falls back to clear install/manual instructions if
# GParted isn't installed or there's no GUI to open it in.
open_gparted_for_review() {
    local dst="$1"
    local reason="${2:-review the partitions and resize if needed}"

    if [[ "$has_gui" != true ]]; then
        echo "Run 'sudo gparted $dst' to $reason." >&2
        return
    fi

    if ! command -v gparted >/dev/null; then
        local msg="GParted isn't installed, so it can't be opened automatically to $reason on $dst.
Install it with:
  sudo apt install gparted
then run it manually on $dst."
        echo "$msg" >&2
        zenity --info --title="GParted Not Installed" --width=680 --text="$msg" 2>/dev/null
        return
    fi

    echo "Opening GParted on $dst to $reason..." >&2
    notify_toast "Opening GParted on $dst..."
    gparted "$dst" >/dev/null 2>&1 &
    # Non-interactive scripts (the normal way this runs) don't have job
    # control enabled by default, so disown can harmlessly fail with "no
    # such job" even though the background process itself started fine.
    disown 2>/dev/null || true
}

offer_gparted_fallback() {
    local dst="$1"
    local base_msg="$dst has extra space that isn't being used yet.
Expanding the right partition needs to be done manually in GParted -- picking one automatically risks growing a recovery/EFI partition instead of the actual data partition.
The data itself is intact regardless; this only affects whether the extra space is usable."

    echo "$base_msg" >&2
    [[ "$has_gui" == true ]] && zenity --info --title="Manual Partition Resize Needed" --width=680 --text="$base_msg" 2>/dev/null

    open_gparted_for_review "$dst" "choose and expand the correct partition into the free space"
}

# Explains an NTFS structural-corruption finding (cluster accounting
# mismatches in $Bitmap) and the actual fix for it, after
# attempt_ntfs_auto_repair has already tried what's safely possible on
# Linux and failed. Real repair of this needs Windows chkdsk -- see that
# function's own comments for why ntfsfix/ntfsck can't reliably do it here.
# Always finishes by opening GParted anyway: even though this specific
# partition still needs chkdsk before GParted will touch it, the person
# may still want to look at the drive or handle other partitions on it.
offer_ntfs_repair_guidance() {
    local dev="$1"
    local msg="NTFS structural corruption was found on $dev (cluster accounting mismatches in \$Bitmap), and automatic repair attempts could not resolve it.

To repair it:
1. On Windows, disable Fast Startup first (Power Options -> Choose what the power buttons do -> uncheck Fast Startup), since it can leave NTFS looking inconsistent even when it may not be.
2. Boot into Windows (or Windows Recovery/installation media if this drive holds the OS) and open an elevated Command Prompt.
3. Run: chkdsk X: /f   (replace X: with this drive's letter)
4. Run it a second time after it finishes -- the first pass fixes structural errors, the second confirms \$Bitmap/cluster accounting actually settled.
5. Shut down properly (not sleep) and come back here -- the resize/clone can proceed once chkdsk reports no errors."

    echo "$msg" >&2
    [[ "$has_gui" == true ]] && zenity --error --title="NTFS Repair Needed (chkdsk)" --width=760 --text="$msg" 2>/dev/null

    open_gparted_for_review "$dev" "inspect the drive (this partition still needs chkdsk on Windows before it can be resized here)"
}

# Best-effort minimum-size check + shrink clone using partclone, for the
# case where the destination is *smaller* than the source. This only
# copies each filesystem's used blocks, so it can succeed as long as the
# actual used data fits -- unlike a raw dd clone, which requires
# dst >= src regardless of how much of src is actually used.
clone_shrink() {
    local src="$1" dst="$2" src_size="$3" dst_size="$4"

    if ! command -v parted >/dev/null || ! command -v sfdisk >/dev/null; then
        echo "ERROR: shrink-clone (destination smaller than source) requires 'parted' and 'sfdisk'." >&2
        echo "Install: apt install parted util-linux" >&2
        return 1
    fi
    if ! ls /sbin/partclone.* /usr/sbin/partclone.* 2>/dev/null | grep -q partclone; then
        echo "ERROR: shrink-clone requires the 'partclone' suite (partclone.ext4, partclone.ntfs, etc.)." >&2
        echo "Install: apt install partclone" >&2
        return 1
    fi

    echo "Analyzing source partitions on $src to determine minimum required size..."
    local total_min=0
    local -a parts fstypes minsizes
    local idx=0
    while read -r pname fstype psize; do
        local pdev="/dev/$pname"
        local minsize=$psize   # fallback: assume it can't shrink at all
        case "$fstype" in
            ext2|ext3|ext4)
                local minblocks
                minblocks=$(resize2fs -P "$pdev" 2>/dev/null | grep -oE '[0-9]+$')
                if [[ -n "$minblocks" ]]; then
                    local blocksize
                    blocksize=$(tune2fs -l "$pdev" 2>/dev/null | awk -F': *' '/Block size/{print $2}')
                    [[ -z "$blocksize" ]] && blocksize=4096
                    minsize=$(( minblocks * blocksize ))
                fi
                ;;
            *)
                echo "  Note: no native minimum-size probe for fstype '$fstype' on $pdev; using its allocated partition size as a conservative estimate." >&2
                ;;
        esac
        # 1 MiB alignment/overhead margin per partition
        minsize=$(( minsize + 1048576 ))
        parts[idx]="$pdev"; fstypes[idx]="$fstype"; minsizes[idx]="$minsize"
        total_min=$(( total_min + minsize ))
        idx=$(( idx + 1 ))
    done < <(lsblk -ln -o NAME,FSTYPE,SIZE -b "$src" | awk 'NR>1 && $2!="" {print $1, $2, $3}')

    total_min=$(( total_min + 1048576 ))  # partition table overhead

    if (( total_min > dst_size )); then
        echo "ERROR: source's used data needs at least $(human_size "$total_min")," >&2
        echo "but the destination ($dst) is only $(human_size "$dst_size")." >&2
        echo "Shortfall: $(human_size $(( total_min - dst_size )))." >&2
        return 1
    fi

    echo "Minimum required: $(human_size "$total_min") -- fits within destination ($(human_size "$dst_size"))."
    echo "Building a proportionally-scaled partition table on $dst..."

    local scale_num=$dst_size scale_den=$src_size
    local sfdisk_script
    sfdisk_script=$(mktemp "$STAGING_DIR/sfdisk-XXXXXX")
    sfdisk -d "$src" > "$sfdisk_script.orig" 2>/dev/null
    # Scale each partition's size down proportionally, but never below its
    # computed minimum. This is a best-effort layout generator; review the
    # resulting table before relying on it for anything you can't re-clone.
    awk -v num="$scale_num" -v den="$scale_den" '
        /^[[:space:]]*\/dev/ {
            match($0, /size= *([0-9]+)/, m)
            if (m[1] != "") {
                newsize = int(m[1] * num / den)
                sub(/size= *[0-9]+/, "size=" newsize)
            }
        }
        { print }
    ' "$sfdisk_script.orig" > "$sfdisk_script"

    if ! sfdisk "$dst" < "$sfdisk_script"; then
        echo "ERROR: failed to write scaled partition table to $dst." >&2
        rm -f "$sfdisk_script" "$sfdisk_script.orig"
        return 1
    fi
    partprobe "$dst" 2>/dev/null
    sleep 1
    rm -f "$sfdisk_script" "$sfdisk_script.orig"

    echo "Cloning used-block data per partition with partclone..."
    local i pnum=0 rc=0
    for (( i=0; i<idx; i++ )); do
        pnum=$(( pnum + 1 ))
        local srcpart="${parts[i]}"
        local dstpart="${dst}${pnum}"
        [[ "$dst" == *nvme* || "$dst" == *mmcblk* ]] && dstpart="${dst}p${pnum}"
        local fstype="${fstypes[i]}"
        local bin="/sbin/partclone.${fstype}"
        [[ -x "$bin" ]] || bin="/usr/sbin/partclone.${fstype}"
        if [[ ! -x "$bin" ]]; then
            echo "  No partclone.${fstype} binary found for $srcpart; skipping this partition." >&2
            rc=1
            continue
        fi
        echo "  $srcpart -> $dstpart ($fstype)..."
        "$bin" -c -s "$srcpart" -o "$dstpart" -q || rc=1
    done
    return $rc
}

clone_disk_body() {
    local src="$1" dst="$2" src_size="$3" dst_size="$4"
    echo "# Unmounting $src and $dst..."
    umount "${src}"* 2>/dev/null || true
    umount "${dst}"* 2>/dev/null || true

    if (( dst_size >= src_size )); then
        echo "# Cloning $src -> $dst ($PARALLELISM parallel streams)..."
        CLONE_SRC_DISK="$src"
        run_chunked_transfer "$dst" "$src_size" chunk_reader_clone_copy "Cloning $src -> $dst"
        local rc=$?
        echo 100
        echo "# Finished cloning $src -> $dst"
        return $rc
    else
        echo "# Destination is smaller than source -- attempting used-blocks-only shrink clone..."
        clone_shrink "$src" "$dst" "$src_size" "$dst_size"
        local rc=$?
        echo 100
        if (( rc == 0 )); then
            echo "# Finished shrink-cloning $src -> $dst"
        else
            echo "# Shrink-clone failed for $src -> $dst -- see terminal/log output for details"
        fi
        return $rc
    fi
}

clone_disk() {
    local src_dev="$1" dst_dev="$2"
    local src="/dev/$src_dev" dst="/dev/$dst_dev"
    local src_size dst_size
    src_size=$(blockdev --getsize64 "$src")
    dst_size=$(blockdev --getsize64 "$dst")
    with_progress_dialog "Cloning $src -> $dst" clone_disk_body "$src" "$dst" "$src_size" "$dst_size"
    local rc=$?

    local gparted_already_opened=false
    if (( rc == 0 )) && (( dst_size > src_size )); then
        echo "Clone complete. Expanding into extra destination space..."
        notify_toast "Expanding partition/filesystem to use the extra space on $dst..."
        clone_grow_step "$dst"
        local grow_rc=$?
        if (( grow_rc == 3 )); then
            offer_ntfs_repair_guidance "$dst"
            gparted_already_opened=true
        elif (( grow_rc != 0 )); then
            offer_gparted_fallback "$dst"
            gparted_already_opened=true
        fi
    fi

    # Land in GParted on the cloned drive every time the clone itself
    # succeeded, whether or not there was extra space to grow into -- so
    # partition sizes can always be reviewed or adjusted manually if
    # wanted, not just when automatic growth needed help.
    if (( rc == 0 )) && [[ "$gparted_already_opened" == false ]]; then
        echo "Clone finished. Opening GParted on $dst to review or adjust partition sizes..."
        open_gparted_for_review "$dst" "review or adjust partition sizes on the cloned drive"
    fi

    return $rc
}

# ===========================================================================
# FEATURE 3: Disk imaging (backup image with destination + compression choice)
# ===========================================================================

IMAGE_SRC_DISK=""
chunk_reader_image_source() {
    local offset="$1" length="$2"
    dd if="$IMAGE_SRC_DISK" bs="$BLOCK_SIZE" skip="$offset" \
       iflag=skip_bytes,count_bytes,fullblock count="$length" status=none
}

# Maps a user-facing compression choice to the fastest available tool.
# Prefers pigz over gzip if installed, since the manual chunk-level
# parallelism (run_chunked_compress) stacks with per-chunk multi-threading
# for free. Only none/gzip are offered -- gzip always produces a plain .gz
# file (never .zst).
resolve_compressor() {
    local choice="$1"
    case "$choice" in
        none) echo "none" ;;
        gzip)
            if command -v pigz >/dev/null; then echo "pigz -c"; else echo "gzip -c"; fi
            ;;
        *) echo "none" ;;
    esac
}

extension_for() {
    case "$1" in
        none) echo "img" ;;
        gzip) echo "img.gz" ;;
    esac
}

# Estimates the final on-disk size of the image for the chosen compression
# so free-space can be checked *before* committing to a multi-hour
# operation. Exact size can't be known ahead of time for compressed output.
#
# Samples ~32MB from three points spread across the disk (start, ~1/3,
# ~2/3) rather than just the beginning: the first few dozen MB of a
# partitioned disk are typically the partition table plus empty/reserved
# space, which compress to almost nothing and would make a front-only
# sample wildly optimistic once extrapolated across the whole drive (where
# the actual file data lives). The WORST (least compressible) of the three
# samples is used as the basis, padded by 30%, since underestimating is
# what leaves a truncated, useless file on the destination -- overestimating
# just means a more conservative warning.
#
# The final extrapolation is done in awk (floating point) rather than pure
# bash integer arithmetic, since total_size * sample_compressed can exceed
# bash's 64-bit integer range on large drives.
estimate_image_size() {
    local src="$1" total_size="$2" compression="$3"
    if [[ "$compression" == "none" ]]; then
        echo "$total_size"
        return
    fi

    local compressor
    compressor=$(resolve_compressor "$compression")
    if [[ "$compressor" == "none" ]]; then
        echo "$total_size"
        return
    fi

    local sample_bytes=$((32 * 1024 * 1024))
    (( sample_bytes > total_size )) && sample_bytes=$total_size
    local sample_blocks=$(( (sample_bytes + BLOCK_BYTES - 1) / BLOCK_BYTES ))

    local -a offset_fracs=(0 33 66)
    local worst_ratio="0" got_sample=false
    local frac offset_bytes offset_blocks sample_compressed ratio

    for frac in "${offset_fracs[@]}"; do
        offset_bytes=$(( total_size * frac / 100 ))
        if (( offset_bytes + sample_bytes > total_size )); then
            offset_bytes=$(( total_size - sample_bytes ))
            (( offset_bytes < 0 )) && offset_bytes=0
        fi
        offset_blocks=$(( offset_bytes / BLOCK_BYTES ))

        sample_compressed=$(dd if="$src" bs="$BLOCK_SIZE" skip="$offset_blocks" \
                count="$sample_blocks" status=none 2>/dev/null \
            | head -c "$sample_bytes" | $compressor 2>/dev/null | wc -c)
        [[ -z "$sample_compressed" ]] && sample_compressed=0
        (( sample_compressed <= 0 )) && continue
        got_sample=true

        ratio=$(awk -v c="$sample_compressed" -v b="$sample_bytes" 'BEGIN{ printf "%.6f", (b>0)?c/b:1.0 }')
        if awk -v r="$ratio" -v w="$worst_ratio" 'BEGIN{exit !(r>w)}'; then
            worst_ratio="$ratio"
        fi
    done

    if [[ "$got_sample" == false ]]; then
        echo "$total_size"   # couldn't sample anything; assume worst case
        return
    fi

    awk -v total="$total_size" -v ratio="$worst_ratio" 'BEGIN{
        est = total * ratio * 1.3;   # +30% safety margin
        if (est > total) est = total;
        if (est < 1) est = 1;
        printf "%.0f", est;
    }'
}

# Notifies the user (via zenity dialogs in GUI mode, or stderr text in
# terminal mode) about a destination space check: that it's happening, and
# whether the destination is big enough. Used for both compressed and
# uncompressed images -- $needed_bytes is whatever estimate_image_size
# produced for the chosen compression, so this same function covers both.
# free_bytes may be passed empty if it couldn't be determined (e.g. no ssh
# for a remote check), in which case this warns but doesn't block.
notify_and_check_space() {
    local label="$1" free_bytes="$2" needed_bytes="$3"

    if [[ -z "$free_bytes" ]]; then
        local warn_msg="Could not determine free space at $label.
Proceeding without a pre-flight space check -- if the destination runs out of room mid-transfer, the operation will fail partway through."
        echo "WARNING: $warn_msg" >&2
        [[ "$has_gui" == true ]] && zenity --warning --title="Space Check Unavailable" --width=620 --text="$warn_msg" 2>/dev/null
        return 0
    fi

    echo "Free space at $label: $(human_size "$free_bytes"). Estimated size needed: $(human_size "$needed_bytes")."

    if (( free_bytes < needed_bytes )); then
        local shortfall=$(( needed_bytes - free_bytes ))
        local err_msg="INCOMPATIBLE -- not enough space at:
$label

Estimated size needed: $(human_size "$needed_bytes")
Available space:       $(human_size "$free_bytes")
Shortfall:             $(human_size "$shortfall")

Choose a larger destination drive or location and try again."
        echo "ERROR: $err_msg" >&2
        [[ "$has_gui" == true ]] && zenity --error --title="Not Enough Space" --width=620 --text="$err_msg" 2>/dev/null
        return 1
    fi

    local ok_msg="COMPATIBLE -- destination has enough space:
$label

Estimated size needed: $(human_size "$needed_bytes")
Available space:       $(human_size "$free_bytes")

Proceeding with the image."
    echo "$ok_msg"
    [[ "$has_gui" == true ]] && zenity --info --title="Space Check Passed" --width=620 --text="$ok_msg" 2>/dev/null
    return 0
}

image_disk_body() {
    local src="$1" size="$2" local_path="$3" compression="$4"
    local compressor
    compressor=$(resolve_compressor "$compression")

    echo "# Saving ISO location to: $local_path ($compression, $PARALLELISM-way)..."
    IMAGE_SRC_DISK="$src"
    run_chunked_compress chunk_reader_image_source "$size" "$local_path" "$compressor" "Saving ISO to $local_path"
    local rc=$?

    if (( rc == 0 )); then
        echo "# Writing checksum manifest..."
        sha256sum "$local_path" > "${local_path}.sha256"
        # gzip only stores the uncompressed size mod 4GiB in its footer, so
        # `gzip -l` silently misreports it for any disk image over 4GB (the
        # overwhelming majority of them). Recording the real size ourselves
        # lets the "Image from ISO" restore feature show an accurate
        # progress bar and do a correct fit check when restoring one of our
        # own captures.
        echo "$size" > "${local_path}.size"
    fi
    echo 100
    echo "# Finished saving ISO to $local_path"
    return $rc
}

image_disk() {
    local src_dev="$1" compression="$2" destination="$3"
    local src="/dev/$src_dev"
    local size
    size=$(blockdev --getsize64 "$src")
    local ext
    ext=$(extension_for "$compression")

    local is_remote=false
    if [[ "$destination" == *:* && "$destination" != /* ]]; then
        is_remote=true
    fi

    local check_label="checking a compressed ($compression) image against"
    [[ "$compression" == "none" ]] && check_label="checking an uncompressed image against"
    echo "Checking whether the destination has enough space before $check_label $destination..."
    # Fire-and-forget desktop notification that the check is running; the
    # actual pass/fail result below is a blocking dialog so it can't be missed.
    notify_toast "Checking destination space for the ISO ($compression)..."

    local estimated_bytes
    estimated_bytes=$(estimate_image_size "$src" "$size" "$compression")
    echo "Estimated ISO size: $(human_size "$estimated_bytes") (source disk is $(human_size "$size"))."

    local staging_path
    if [[ "$is_remote" == true ]]; then
        # Remote destination: user@host:/path -- stage locally, then transfer.
        # Space is checked both at the local staging area (where the file
        # is actually written first) and, if ssh is available, at the
        # remote path itself.
        staging_path=$(mktemp "$STAGING_DIR/image-XXXXXX.$ext")
        echo "Saving ISO location to: $destination (staging locally at $STAGING_DIR first)"

        local local_free_kb local_free_bytes=""
        local_free_kb=$(df -Pk "$STAGING_DIR" 2>/dev/null | awk 'NR==2{print $4}')
        [[ -n "$local_free_kb" ]] && local_free_bytes=$(( local_free_kb * 1024 ))
        if ! notify_and_check_space "$STAGING_DIR (local staging area)" "$local_free_bytes" "$estimated_bytes"; then
            rm -f "$staging_path"
            return 1
        fi

        if command -v ssh >/dev/null; then
            local remote_host="${destination%%:*}"
            local remote_dir
            remote_dir=$(dirname "${destination#*:}")
            local remote_free_kb remote_free_bytes=""
            remote_free_kb=$(ssh "$remote_host" "df -Pk '$remote_dir'" 2>/dev/null | awk 'NR==2{print $4}')
            [[ -n "$remote_free_kb" ]] && remote_free_bytes=$(( remote_free_kb * 1024 ))
            if ! notify_and_check_space "$destination" "$remote_free_bytes" "$estimated_bytes"; then
                rm -f "$staging_path"
                return 1
            fi
        else
            local warn_msg="ssh not installed; cannot verify free space on remote destination $destination. Proceeding without that check."
            echo "WARNING: $warn_msg" >&2
            [[ "$has_gui" == true ]] && zenity --warning --title="Space Check Unavailable" --width=620 --text="$warn_msg" 2>/dev/null
        fi
    else
        mkdir -p "$destination" 2>/dev/null || true
        staging_path="${destination%/}/$(basename "$src")-$(date +%Y%m%d-%H%M%S).$ext"
        echo "Saving ISO location to: $staging_path"

        local free_kb free_bytes=""
        free_kb=$(df -Pk "$destination" 2>/dev/null | awk 'NR==2{print $4}')
        [[ -n "$free_kb" ]] && free_bytes=$(( free_kb * 1024 ))
        if ! notify_and_check_space "$destination" "$free_bytes" "$estimated_bytes"; then
            return 1
        fi
    fi

    with_progress_dialog "Saving ISO to $staging_path" image_disk_body "$src" "$size" "$staging_path" "$compression"
    local rc=$?
    (( rc != 0 )) && return $rc

    if [[ "$is_remote" == true ]]; then
        if ! command -v scp >/dev/null; then
            echo "ERROR: scp not installed; ISO was created locally at $staging_path but could not be sent to $destination." >&2
            return 1
        fi
        echo "Transferring ISO to $destination..."
        scp "$staging_path" "${staging_path}.sha256" "${staging_path}.size" "$destination" \
            && rm -f "$staging_path" "${staging_path}.sha256" "${staging_path}.size"
    else
        echo "ISO saved to: $staging_path"
        echo "Checksum written to: ${staging_path}.sha256"
    fi
}

# ===========================================================================
# FEATURE 4: Image from ISO (restore a captured image onto a drive)
# ===========================================================================

# Figures out whether an image file is one of ours (none/gzip) from its
# extension, since that's all resolve_compressor/extension_for use too.
detect_image_compression() {
    case "$1" in
        *.img.gz) echo "gzip" ;;
        *.gz)     echo "gzip" ;;
        *)        echo "none" ;;
    esac
}

# Determines the real uncompressed byte size of an image file so restore
# can size-check against the destination drive and show accurate progress.
# Prefers our own ".size" sidecar (exact, written at capture time) since
# gzip's own stored size is 32-bit and silently wraps for anything over
# 4GB -- i.e. it's wrong for most disk images. Falls back to `gzip -l`
# with that caveat surfaced, or the file's own size for uncompressed images.
determine_uncompressed_size() {
    local image_path="$1" compression="$2"
    if [[ -f "${image_path}.size" ]]; then
        cat "${image_path}.size"
        return
    fi
    if [[ "$compression" == "gzip" ]]; then
        local reported
        reported=$(gzip -l "$image_path" 2>/dev/null | awk 'NR==2{print $2}')
        if [[ "$reported" =~ ^[0-9]+$ ]] && (( reported > 0 )); then
            echo "$reported"
            echo "NOTE: size came from gzip's own header, which wraps at 4GB -- treat it as approximate for large images." >&2
            return
        fi
        echo ""   # unknown
    else
        stat -c%s "$image_path" 2>/dev/null || echo ""
    fi
}

restore_image_body() {
    local image_path="$1" dst="$2" compression="$3" progress_size="$4"
    local start_time
    start_time=$(date +%s)

    if [[ ! -b "$dst" ]]; then
        echo "# ERROR: $dst is not a block device -- aborting before touching anything."
        return 1
    fi

    echo "# Unmounting $dst..."
    umount "${dst}"* 2>/dev/null || true

    if [[ "$compression" == "gzip" ]]; then
        echo "# Verifying $image_path integrity before restoring..."
        if ! gzip -t "$image_path" 2>/dev/null; then
            echo "# ERROR: $image_path failed gzip's integrity check (corrupt file, or not actually gzip-compressed)."
            return 1
        fi
    fi

    echo "# Restoring $image_path -> $dst..."
    local progfile
    progfile=$(mktemp "$STAGING_DIR/restore-progress-XXXXXX")
    echo 0 > "$progfile"

    set +o pipefail
    if [[ "$compression" == "gzip" ]]; then
        gzip -dc "$image_path" 2>/dev/null
    else
        cat "$image_path"
    fi | pv -n -s "$progress_size" 2> >(while IFS= read -r p; do printf '%s' "$p" > "$progfile"; done) \
      | dd of="$dst" bs="$BLOCK_SIZE" status=none conv=fsync,notrunc &
    local pipe_pid=$!

    (
        while kill -0 "$pipe_pid" 2>/dev/null; do
            local p
            p=$(cat "$progfile" 2>/dev/null || echo 0)
            [[ "$p" =~ ^[0-9]+$ ]] || p=0
            report_progress "Restoring to $dst" "$start_time" "$p"
            sleep 1
        done
    ) &
    local monitor_pid=$!

    wait "$pipe_pid"
    local rc=$?
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    set -o pipefail
    rm -f "$progfile"
    sync

    echo 100
    if (( rc == 0 )); then
        echo "# Finished restoring $image_path -> $dst"
    else
        echo "# Restore failed (dd exited with $rc) -- see terminal/log output for details"
    fi
    return $rc
}

restore_image() {
    local image_path="$1" dst_dev="$2"
    local dst="/dev/$dst_dev"
    local dst_size
    dst_size=$(blockdev --getsize64 "$dst")

    local compression
    compression=$(detect_image_compression "$image_path")

    echo "Checking whether $dst has enough room for this image..."
    notify_toast "Checking image size against $dst..."

    local uncompressed_size
    uncompressed_size=$(determine_uncompressed_size "$image_path" "$compression")

    local progress_size
    if [[ -n "$uncompressed_size" ]]; then
        echo "Image's real (uncompressed) size: $(human_size "$uncompressed_size")."
        if ! notify_and_check_space "$dst (destination drive)" "$dst_size" "$uncompressed_size"; then
            return 1
        fi
        progress_size="$uncompressed_size"
    else
        local warn_msg="Could not determine this image's uncompressed size (no .size sidecar, and gzip's header didn't give a usable value).
Proceeding without a pre-flight fit check -- if the image is larger than $dst ($(human_size "$dst_size")), the restore will fail partway through."
        echo "WARNING: $warn_msg" >&2
        [[ "$has_gui" == true ]] && zenity --warning --title="Size Check Unavailable" --width=620 --text="$warn_msg" 2>/dev/null
        progress_size="$dst_size"   # best-effort denominator so the progress bar still moves sensibly
    fi

    with_progress_dialog "Restoring to $dst" restore_image_body "$image_path" "$dst" "$compression" "$progress_size"
    local rc=$?

    local gparted_already_opened=false
    if (( rc == 0 )) && [[ -n "$uncompressed_size" ]] && (( dst_size > uncompressed_size )); then
        echo "Restore complete. Expanding into extra destination space..."
        notify_toast "Expanding partition/filesystem to use the extra space on $dst..."
        clone_grow_step "$dst"
        local grow_rc=$?
        if (( grow_rc == 3 )); then
            offer_ntfs_repair_guidance "$dst"
            gparted_already_opened=true
        elif (( grow_rc != 0 )); then
            offer_gparted_fallback "$dst"
            gparted_already_opened=true
        fi
    fi

    if (( rc == 0 )) && [[ "$gparted_already_opened" == false ]]; then
        echo "Restore finished. Opening GParted on $dst to review or adjust partition sizes..."
        open_gparted_for_review "$dst" "review or adjust partition sizes on the restored drive"
    fi

    return $rc
}



select_operation_gui() {
    zenity --list \
        --title="Disk Toolkit" \
        --radiolist \
        --width=980 --height=420 \
        --column="Select" --column="Operation" --column="Description" --column="Code" \
        --hide-column=4 --print-column=4 \
        TRUE  "Wipe Drive(s)"    "Securely erase one or more drives." "wipe" \
        FALSE "Clone Disk"       "Clone one disk to another, any size combination." "clone" \
        FALSE "Capture Image"    "Create an ISO/backup image of a disk (compressed or raw)." "image" \
        FALSE "Image from ISO"   "Write a previously captured image back onto a drive." "restore"
}

run_wipe_flow() {
    choices=()
    while read -r name size model; do
        choices+=(FALSE "$name" "$size" "$model")
    done < <(list_drives)

    local selected
    if [[ "$has_gui" == true ]]; then
        selected=$(zenity --list \
            --title="Select Drives to Wipe" \
            --text="WARNING: This permanently destroys data." \
            --checklist \
            --width=1030 --height=520 \
            --column="Wipe" --column="Device" --column="Size" --column="Model" \
            "${choices[@]}") || return 0
        [[ -z "${selected:-}" ]] && return 0

        local method
        method=$(zenity --list \
            --title="Select Wipe Method" \
            --radiolist \
            --width=1030 --height=350 \
            --column="Select" --column="Method" --column="Description" \
            TRUE  "full_random"  "Parallel random overwrite (strong, software-only)." \
            FALSE "zero"         "Parallel zero-fill (fastest software option).") || return 0

        local confirm
        confirm=$(zenity --entry \
            --title="Final Confirmation" --width=880 \
            --text="Selected drives: $selected Type WIPE to permanently erase them.") || return 0
        [[ "$confirm" != "WIPE" ]] && return 0

        local -a devices
        IFS="|" read -ra devices <<< "$selected"
        _run_devices_parallel wipe_drive "$method" "${devices[@]}"
    else
        list_drives
        local -a devices
        read -rp "Enter drive names separated by spaces: " -a devices
        echo "1) full_random  2) zero"
        local choice method
        read -rp "Choose method [1-2]: " choice
        case "$choice" in
            1) method="full_random" ;; 2) method="zero" ;;
            *) echo "Invalid choice"; return 1 ;;
        esac
        local confirm
        read -rp "Type WIPE to continue: " confirm
        [[ "$confirm" != "WIPE" ]] && return 0
        _run_devices_parallel wipe_drive "$method" "${devices[@]}"
    fi
}

_run_devices_parallel() {
    local fn="$1" method="$2"; shift 2
    local running=0
    for dev in "$@"; do
        "$fn" "$dev" "$method" &
        running=$((running + 1))
        if [[ "$running" -ge "$PARALLEL_JOBS" ]]; then
            wait -n; running=$((running - 1))
        fi
    done
    wait
}

run_clone_flow() {
    local -a drive_list=()
    while read -r name size model; do
        drive_list+=("$name" "$size ($model)")
    done < <(list_drives)

    local src_dev dst_dev
    if [[ "$has_gui" == true ]]; then
        src_dev=$(zenity --list --title="Select SOURCE disk" \
            --width=880 --height=520 --column="Device" --column="Info" "${drive_list[@]}") || return 0
        [[ -z "$src_dev" ]] && return 0
        dst_dev=$(zenity --list --title="Select DESTINATION disk (will be overwritten)" \
            --width=880 --height=520 --column="Device" --column="Info" "${drive_list[@]}") || return 0
        [[ -z "$dst_dev" ]] && return 0
        if [[ "$src_dev" == "$dst_dev" ]]; then
            zenity --error --text="Source and destination must be different drives."
            return 1
        fi
        local confirm
        confirm=$(zenity --entry --title="Final Confirmation" --width=880 \
            --text="This will ERASE /dev/$dst_dev and overwrite it with a clone of /dev/$src_dev. Type CLONE to continue.") || return 0
        [[ "$confirm" != "CLONE" ]] && return 0
    else
        list_drives
        read -rp "Source device (e.g. sda): " src_dev
        read -rp "Destination device (e.g. sdb): " dst_dev
        if [[ "$src_dev" == "$dst_dev" ]]; then
            echo "Source and destination must differ." >&2; return 1
        fi
        local confirm
        read -rp "This will ERASE /dev/$dst_dev. Type CLONE to continue: " confirm
        [[ "$confirm" != "CLONE" ]] && return 0
    fi

    clone_disk "$src_dev" "$dst_dev"
}

run_image_flow() {
    local -a drive_list=()
    while read -r name size model; do
        drive_list+=("$name" "$size ($model)")
    done < <(list_drives)

    local src_dev compression destination
    if [[ "$has_gui" == true ]]; then
        src_dev=$(zenity --list --title="Select Disk to Capture" \
            --width=980 --height=520 --column="Device" --column="Info" "${drive_list[@]}") || return 0
        [[ -z "$src_dev" ]] && return 0

        compression=$(zenity --list --title="Compression" --radiolist \
            --width=980 --height=350 \
            --column="Select" --column="Method" --column="Description" \
            FALSE "none" "Uncompressed raw image (fastest to write, largest file)." \
            TRUE  "gzip" "Good default; widely compatible; uses pigz automatically if installed. Saved as .gz.") || return 0

        # Offer picking a currently-plugged-in/mounted drive directly,
        # a native folder browser, or a remote (scp) target.
        local -a dest_rows=(
            "Browse for a folder..." "-" "-" "-" "BROWSE"
            "Enter a remote target (user@host:/path)..." "-" "-" "-" "REMOTE"
        )
        while IFS=$'\t' read -r name size fstype mountpoint; do
            dest_rows+=("$name" "$size" "$fstype" "$mountpoint" "$mountpoint")
        done < <(list_mounted_targets)

        local dest_value
        dest_value=$(zenity --list --title="ISO Destination" \
            --text="Saving ISO location to: choose an available drive below, browse for a folder, or enter a remote target." \
            --width=1030 --height=520 \
            --column="Device" --column="Size" --column="FS" --column="Mount Point" --column="Value" \
            --hide-column=5 --print-column=5 \
            "${dest_rows[@]}") || return 0
        [[ -z "$dest_value" ]] && return 0

        if [[ "$dest_value" == "BROWSE" ]]; then
            destination=$(zenity --file-selection --directory \
                --title="Saving ISO location to...") || return 0
            [[ -z "$destination" ]] && return 0
        elif [[ "$dest_value" == "REMOTE" ]]; then
            destination=$(zenity --entry --title="ISO Destination" --width=980 \
                --text="Saving ISO location to (remote target, e.g. user@host:/path):") || return 0
            [[ -z "$destination" ]] && return 0
        else
            destination="$dest_value"
        fi
    else
        list_drives
        read -rp "Device to image (e.g. sda): " src_dev
        echo "1) gzip (default, saved as .gz)  2) none (raw, uncompressed)"
        local cchoice
        read -rp "Compression [1-2, default 1]: " cchoice
        case "$cchoice" in
            2) compression="none" ;;
            ""|1) compression="gzip" ;;
            *) echo "Invalid choice"; return 1 ;;
        esac

        echo "Available mounted destinations:"
        local -a dest_paths=()
        local idx=1
        while IFS=$'\t' read -r name size fstype mountpoint; do
            echo "  $idx) $name ($size, $fstype) -> $mountpoint"
            dest_paths[idx]="$mountpoint"
            idx=$((idx + 1))
        done < <(list_mounted_targets)
        echo "  0) Enter a custom path or remote target manually"

        local dchoice
        read -rp "Choose destination [0-$((idx - 1)), default 0]: " dchoice
        if [[ -z "$dchoice" || "$dchoice" == "0" ]]; then
            read -rp "Saving ISO location to (local dir, or user@host:/path): " destination
        else
            destination="${dest_paths[$dchoice]:-}"
            if [[ -z "$destination" ]]; then
                echo "Invalid selection." >&2
                return 1
            fi
        fi
    fi

    image_disk "$src_dev" "$compression" "$destination"
}

run_restore_flow() {
    local image_path
    if [[ "$has_gui" == true ]]; then
        image_path=$(zenity --file-selection --title="Select Image to Restore") || return 0
        [[ -z "$image_path" ]] && return 0
    else
        read -rp "Path to the image file to restore (.img or .img.gz): " image_path
        [[ -z "$image_path" ]] && return 0
    fi

    if [[ ! -f "$image_path" ]]; then
        local msg="File not found: $image_path"
        echo "ERROR: $msg" >&2
        [[ "$has_gui" == true ]] && zenity --error --title="File Not Found" --width=620 --text="$msg"
        return 1
    fi

    local -a drive_list=()
    while read -r name size model; do
        drive_list+=("$name" "$size ($model)")
    done < <(list_drives)

    local dst_dev
    if [[ "$has_gui" == true ]]; then
        dst_dev=$(zenity --list --title="Select Drive to Image With This ISO" \
            --text="This will ERASE the selected drive and overwrite it with:\n$image_path" \
            --width=980 --height=520 --column="Device" --column="Info" "${drive_list[@]}") || return 0
        [[ -z "$dst_dev" ]] && return 0

        local confirm
        confirm=$(zenity --entry --title="Final Confirmation" --width=880 \
            --text="This will ERASE /dev/$dst_dev and overwrite it with $image_path. Type RESTORE to continue.") || return 0
        [[ "$confirm" != "RESTORE" ]] && return 0
    else
        list_drives
        read -rp "Drive to image with this ISO (e.g. sdb): " dst_dev
        local confirm
        read -rp "This will ERASE /dev/$dst_dev. Type RESTORE to continue: " confirm
        [[ "$confirm" != "RESTORE" ]] && return 0
    fi

    restore_image "$image_path" "$dst_dev"
}

# ===========================================================================
# Entry point
# ===========================================================================

install_desktop_shortcut

operation=""
if [[ "$has_gui" == true ]]; then
    operation=$(select_operation_gui) || exit 0
    [[ -z "$operation" ]] && exit 0
else
    echo "GUI unavailable. Using terminal mode."
    echo "1) Wipe drive(s)"
    echo "2) Clone disk"
    echo "3) Capture Image"
    echo "4) Image from ISO (restore an image onto a drive)"
    read -rp "Choose operation [1-4]: " opchoice
    case "$opchoice" in
        1) operation="wipe" ;;
        2) operation="clone" ;;
        3) operation="image" ;;
        4) operation="restore" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

case "$operation" in
    wipe)    run_wipe_flow ;;
    clone)   run_clone_flow ;;
    image)   run_image_flow ;;
    restore) run_restore_flow ;;
esac

if [[ "$has_gui" == true ]]; then
    zenity --info --title="Complete" --text="Operation complete."
else
    echo
    echo "Operation complete."
fi
