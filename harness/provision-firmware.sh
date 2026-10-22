#!/usr/bin/bash
# harness/provision-firmware.sh — place the per-machine Apple Wi-Fi firmware on an
# installed target, in BOTH name forms.
#
# Why this exists: the firmware copy is the step that fails silently. It bit this bench
# twice — once because a reinstall wipes /var, and once because /run/media/matt/root was
# not a mount at copy time, so `mkdir -p` created a plain directory on the host and the
# files went there. A boot log is far too late to discover either.
#
# Why two name forms: on kernel 7.2.5 brcmfmac asks for the unqualified base name
# (brcmfmac4364b3-pcie.bin) and never resolves a board type, while the working 7.2.11 host
# asks for the board-qualified name (….apple,trinidad-X3.bin). Installing both makes the
# radio work on either, and the extra copies are harmless. See
# research/findings/module-pipeline.md §7 — the board-type difference is an open question,
# and this is a workaround, not a fix.
#
# Usage:
#   sudo harness/provision-firmware.sh --target-root /run/media/matt/root
#   sudo harness/provision-firmware.sh --target-root … --source /path/to/brcm
#   harness/provision-firmware.sh --target-root … --dry-run     # no root needed
#
# It never mounts, never formats, and never writes outside <target-root>/ostree/deploy/*/var.

set -euo pipefail

TARGET_ROOT=""
SOURCE_DIR="/lib/firmware/brcm"
DRY_RUN=0
REQUIRE_COUNT=0

die()  { printf 'error: %s: %s\n' "$1" "$2" >&2; exit "${3:-3}"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while (( $# > 0 )); do
  case $1 in
    --target-root) [[ $# -ge 2 ]] || usage 2; TARGET_ROOT=$2; shift 2 ;;
    --source)      [[ $# -ge 2 ]] || usage 2; SOURCE_DIR=$2; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --require-count) REQUIRE_COUNT=1; shift ;;
    -h|--help)     usage 0 ;;
    *) printf 'error: E_USAGE: unknown argument: %s\n' "$1" >&2; usage 2 ;;
  esac
done

[[ -n $TARGET_ROOT ]] || die E_NO_TARGET "--target-root is required. Refusing to guess a disk." 2
[[ -d $TARGET_ROOT ]] || die E_NO_TARGET "no such directory: $TARGET_ROOT" 3

# --- 1. it must be a MOUNT, not an empty directory that looks like one -----------------
# `findmnt --target` reports the mount CONTAINING a path, so it returns something for any
# existing directory and cannot answer "is this path itself a mount". Use mountpoint(1)
# for that question; fall back to comparing findmnt's target with the path.
if command -v mountpoint >/dev/null 2>&1; then
  mountpoint -q "$TARGET_ROOT" || die E_NOT_MOUNTED \
    "$TARGET_ROOT is not a mount point. Copying here would write to the host root filesystem, not the target. Mount the target first (udisksctl mount -b /dev/sdXN)." 3
else
  mnt=$(/usr/bin/findmnt -no TARGET --target "$TARGET_ROOT" 2>/dev/null || true)
  [[ -n $mnt && $(readlink -f "$mnt") == "$(readlink -f "$TARGET_ROOT")" ]] || die E_NOT_MOUNTED \
    "$TARGET_ROOT is not a mount point (findmnt target is '${mnt:-<none>}'). Mount the target first." 3
fi
source_dev=$(/usr/bin/findmnt -no SOURCE --target "$TARGET_ROOT" 2>/dev/null || true)
printf 'target:  %s on %s\n' "$TARGET_ROOT" "$source_dev"

# --- 2. it must be an installed bootc tree with a persistent /var ----------------------
VAR=""
for candidate in "$TARGET_ROOT"/ostree/deploy/*/var; do
  [[ -d $candidate ]] && { VAR=$candidate; break; }
done
[[ -n $VAR ]] || die E_NO_VAR \
  "no ostree/deploy/*/var under $TARGET_ROOT — this is not an installed bootc target, or it is not mounted." 3
printf 'var:     %s\n' "$VAR"

# --- 3. the source firmware must be there ---------------------------------------------
shopt -s nullglob
qualified=("$SOURCE_DIR"/brcmfmac*-pcie.apple,*)
(( ${#qualified[@]} > 0 )) || die E_NO_SOURCE \
  "no brcmfmac*-pcie.apple,* files in $SOURCE_DIR. The per-machine payload is missing." 3
printf 'source:  %d board-qualified file(s) in %s\n' "${#qualified[@]}" "$SOURCE_DIR"

# --- 4. build the generic names from the qualified ones --------------------------------
# For each extension pick the candidate with the -X3 revision if there is one, else the
# first. Never invent a name that has no source file behind it.
declare -A generic_src=()
for f in "${qualified[@]}"; do
  base=${f##*/}                     # brcmfmac4364b3-pcie.apple,trinidad-X3.clm_blob
  stem=${base%%.apple,*}            # brcmfmac4364b3-pcie
  ext=${base##*.}                   # clm_blob | bin | txt | txcap_blob
  label="$stem.$ext"
  if [[ -z ${generic_src[$label]+x} || $base == *-X3.* ]]; then
    generic_src[$label]=$f
  fi
done

printf '\nplan (%d qualified + %d generic copies):\n' "${#qualified[@]}" "${#generic_src[@]}"
for f in "${qualified[@]}"; do printf '  copy    %s\n' "${f##*/}"; done
for label in "${!generic_src[@]}"; do printf '  link-as %s  <- %s\n' "$label" "${generic_src[$label]##*/}"; done

if (( DRY_RUN )); then
  printf '\ndry-run: nothing was written.\n'
  exit 0
fi

(( EUID == 0 )) || die E_NOT_ROOT "writing the target needs root; re-run under sudo." 5

DEST="$VAR/lib/firmware/brcm"
mkdir -p "$DEST"

for f in "${qualified[@]}"; do
  cp -f "$f" "$DEST/"
done
for label in "${!generic_src[@]}"; do
  cp -f "${generic_src[$label]}" "$DEST/$label"
done
sync

# --- 5. verify. The whole point of this script is that this step cannot be skipped. ---
missing=0
for f in "${qualified[@]}"; do
  [[ -s "$DEST/${f##*/}" ]] || { warn "missing after copy: ${f##*/}"; missing=1; }
done
for label in "${!generic_src[@]}"; do
  [[ -s "$DEST/$label" ]] || { warn "missing after copy: $label"; missing=1; }
done
(( missing == 0 )) || die E_VERIFY "the copy did not land. Check that $TARGET_ROOT is still mounted." 6

count=$(find "$DEST" -maxdepth 1 -type f -name 'brcmfmac*-pcie*' | wc -l | tr -d '[:space:]')
printf '\nplaced %s file(s) in %s\n' "$count" "$DEST"
if (( REQUIRE_COUNT > 0 )); then
  (( count >= REQUIRE_COUNT )) || die E_VERIFY "expected at least $REQUIRE_COUNT files, found $count" 6
fi
# --- 6. record the import, so bluefin-t2 report can say "imported" --------------------
# The 2026-10-22 bench proved this matters: Wi-Fi worked, but report said not-ok because
# no state file existed — the copy had been made by this script, which predates the
# helper's marker. The state file lives in the deployment's /var, which is where the
# booted system reads it.
state_dir="$VAR/lib/bluefin-t2"
mkdir -p "$state_dir"
payload_sha=$( ( cd "$DEST" && sha256sum brcmfmac*-pcie* 2>/dev/null | sort ) | sha256sum | cut -d' ' -f1)
{
  printf 'payload_sha256=%s\n' "$payload_sha"
  printf 'source=harness/provision-firmware.sh\n'
  printf 'files=%s\n' "$count"
} > "$state_dir/firmware.state"
sync
printf 'state:   %s (payload_sha256=%s)\n' "$state_dir/firmware.state" "$payload_sha"

printf 'done. Unmount the target before booting it.\n'
