#!/bin/bash
# prepare-usb.sh — the macOS half of the bluefin-t2 install kit.
#
#   ./prepare-usb.sh --check   --iso bluefin-t2-XXXX.iso [--firmware-dir DIR]
#   ./prepare-usb.sh --disk diskN --iso ... [--sha256 FILE]
#
# It captures this Mac's Apple Wi-Fi firmware, verifies the ISO, writes it to a USB drive
# after a typed confirmation, and puts the firmware on the USB ESP where the ISO's
# post-script finds it (iso/kickstart/bluefin-t2.ks).
#
# --check writes nothing. --dry-run prints the plan and writes nothing; it is the only mode
# that runs on a non-macOS host, which is how the release checklist reviews it.
#
# macOS constraint: /bin/bash is 3.2. No mapfile, no ${var,,}, no associative arrays.

set -euo pipefail

FW_SRC=/usr/share/firmware/wifi
VERSION_FILE=$(dirname "$0")/VERSION
ISO=""
SHA256=""
DISK=""
FIRMWARE_DIR=""
MODE=write

die() { echo "prepare-usb.sh: $*" >&2; exit 1; }
# macOS has shasum; the --dry-run review may run on Linux, which has sha256sum.
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else sha256sum "$1" | cut -d' ' -f1; fi
}
log() { echo "prepare-usb.sh: $*"; }

usage() {
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while (( $# )); do
    case "$1" in
        --check)  MODE=check; shift ;;
        --dry-run) MODE=dry-run; shift ;;
        --iso)    ISO="${2:?--iso needs a value}"; shift 2 ;;
        --sha256) SHA256="${2:?--sha256 needs a value}"; shift 2 ;;
        --disk)   DISK="${2:?--disk needs a value}"; shift 2 ;;
        --firmware-dir) FIRMWARE_DIR="${2:?--firmware-dir needs a value}"; shift 2 ;;
        --version) cat "$VERSION_FILE" 2>/dev/null || echo "unknown"; exit 0 ;;
        -h|--help) usage 0 ;;
        *) echo "prepare-usb.sh: unknown argument: $1" >&2; usage 1 ;;
    esac
done

[[ -n "$ISO" ]] || die "--iso is required"
[[ -f "$ISO" ]] || die "ISO not found: $ISO"

# --- 1. the ISO ------------------------------------------------------------------------
if [[ -n "$SHA256" ]]; then
    expected=$(cut -d' ' -f1 "$SHA256")
    actual=$(sha256_of "$ISO")
    [[ "$actual" == "$expected" ]] || die "ISO checksum mismatch: expected $expected, got $actual"
    log "ISO checksum verified"
elif [[ -f "$ISO.sha256" ]]; then
    expected=$(cut -d' ' -f1 "$ISO.sha256")
    actual=$(sha256_of "$ISO")
    [[ "$actual" == "$expected" ]] || die "ISO checksum mismatch"
    log "ISO checksum verified ($ISO.sha256)"
else
    log "no checksum file next to the ISO; publish a SHA256SUMS with the release and pass --sha256"
fi

# --- 2. firmware -----------------------------------------------------------------------
if [[ -n "$FIRMWARE_DIR" ]]; then
    [[ -d "$FIRMWARE_DIR" ]] || die "--firmware-dir does not exist: $FIRMWARE_DIR"
    FW_SRC="$FIRMWARE_DIR"
fi
[[ -d "$FW_SRC" ]] || die "no firmware directory: $FW_SRC (run this on the Mac, or pass --firmware-dir)"

fw_files=$(ls "$FW_SRC"/*.trx "$FW_SRC"/*.clmb "$FW_SRC"/*.txcb "$FW_SRC"/P-*.txt 2>/dev/null || true)
[[ -n "$fw_files" ]] || die "no Apple firmware in $FW_SRC. Enable Wi-Fi, reboot macOS, and retry, or use --firmware-dir"
fw_count=$(printf '%s\n' "$fw_files" | wc -l | tr -d ' ')
log "captured $fw_count firmware file(s) from $FW_SRC"
printf '%s\n' "$fw_files" | while read -r f; do [[ -n "$f" ]] && log "  $(basename "$f")"; done
if [[ "$fw_count" -lt 4 ]]; then
    log "note: fewer than the four usual files; if Wi-Fi misbehaves after install, recapture with Wi-Fi on"
fi

model=$(sysctl -n hw.model 2>/dev/null || echo unknown)
log "model: $model"
log "these files are specific to this Mac and cannot be downloaded later"

if [[ "$MODE" == check ]]; then
    log "--check complete: nothing was written"
    exit 0
fi

# --- 3. the disk -----------------------------------------------------------------------
[[ -n "$DISK" ]] || die "--disk is required to write (e.g. --disk disk2); --check writes nothing"
case "$DISK" in
    disk*) : ;;
    *) die "--disk takes a disk identifier such as disk2, not a partition or a path" ;;
esac
iso_size=$(wc -c < "$ISO" | tr -d ' ')

if [[ "$MODE" == dry-run ]]; then
    log "--dry-run: would erase ${DISK:-<no --disk given>}, write $ISO ($iso_size bytes),"
    log "           then copy the firmware to <USB ESP>/kait2en/firmware/wifi/ with SHA256SUMS"
    exit 0
fi

command -v diskutil >/dev/null 2>&1 || die "diskutil is missing; the write path runs on macOS"
disk_size=$(diskutil info "$DISK" 2>/dev/null | awk -F: '/Disk Size/ {gsub(/[^0-9]/,"",$2); print $2; exit}')
[[ -n "$disk_size" ]] || die "cannot read the size of $DISK"
(( disk_size > iso_size )) || die "$DISK is smaller than the ISO ($iso_size bytes)"
log "target: $DISK ($disk_size bytes); ISO $iso_size bytes"
diskutil list "$DISK" || true

printf 'Type ERASE %s to continue: ' "$DISK"
read -r answer
[[ "$answer" == "ERASE $DISK" ]] || die "confirmation did not match; nothing was written"

# --- 4. write, then inject the payload -------------------------------------------------
log "writing $ISO to $DISK"
diskutil unmountDisk "$DISK" || die "cannot unmount $DISK"
rdisk="/dev/r${DISK#/dev/}"
dd if="$ISO" of="$rdisk" bs=4m || die "dd failed"
sync
log "written; verifying the ISO read-back"
readback=$(dd if="/dev/${DISK#/dev/}" bs=4m count=$((iso_size / 4194304 + 1)) 2>/dev/null | head -c "$iso_size" | shasum -a 256 | cut -d' ' -f1)
expected_iso=$(sha256_of "$ISO")
[[ "$readback" == "$expected_iso" ]] || die "read-back checksum differs; do not boot from this stick"

esp="${DISK}s1"
diskutil mount "$esp" >/dev/null || die "cannot mount the USB ESP ($esp)"
esp_mnt="/Volumes/$(diskutil info "$esp" | awk -F: '/Volume Name/ {gsub(/^ +| +$/,"",$2); print $2; exit}')"
[[ -d "$esp_mnt" ]] || die "ESP mount point not found"
payload="$esp_mnt/kait2en/firmware/wifi"
mkdir -p "$payload"
# copy the captured files, then write the marker the post-script verifies
printf '%s\n' "$fw_files" | while read -r f; do
    [[ -n "$f" ]] || continue
    cp -f "$f" "$payload/" || die "copy failed: $f"
done
( cd "$payload" && shasum -a 256 ./* > SHA256SUMS )
printf '%s\n' "$fw_files" | while read -r f; do
    [[ -n "$f" ]] || continue
    cmp -s "$f" "$payload/$(basename "$f")" || die "verification failed: $(basename "$f")"
done
sync
diskutil unmount "$esp" >/dev/null || true

cat <<EOF

Done. Next:
  1. Reboot the Mac holding Option and choose the USB drive.
  2. The internal keyboard and trackpad work in the installer.
  3. The installer carries the firmware into the installed system itself.
  4. First login reports what works; Wi-Fi will associate after the import.
EOF
