#!/usr/bin/env bash
# shellcheck shell=bash
#
# harness/lib/host-common.sh — helpers shared by the Tier 2 bench scripts that run on
# the bench HOST (install-to-disk.sh, attempt.sh, evaluate.sh, selftest.sh).
#
# Sourced, never executed. Host-side only: it assumes bash 4+, jq, lsblk, findmnt and
# (for some callers) skopeo. The scripts under harness/rootfs/ run on the installed
# image and must NOT source this file — that image has no jq and may have no python3.
#
# Nothing here writes to a block device, mounts anything, or runs a container. The
# device helpers are read-only readings of sysfs and lsblk output.

HC_VERSION="1"

hc_log()  { printf '%s\n' "$*" >&2; }
hc_warn() { printf 'warning: %s\n' "$*" >&2; }

# hc_die <exit-code> <NAMED_ERROR> <message...>
hc_die() {
  local code=$1 name=$2
  shift 2
  printf 'error: %s: %s\n' "$name" "$*" >&2
  exit "$code"
}

# hc_require_cmd <cmd>... — exit 5 if any is missing.
hc_require_cmd() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'error: E_MISSING_TOOL: required command not found: %s\n' "$cmd" >&2
      missing=1
    fi
  done
  (( missing == 0 )) || exit 5
}

hc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# A run id is a UTC timestamp plus four hex digits: sortable, unique enough for a
# human-driven bench, and safe as a directory name.
hc_run_id() {
  printf '%s-%04x\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(( RANDOM % 65536 ))"
}

# This host has more than one lsblk/findmnt on PATH (a Homebrew util-linux shadows the
# system one). Prefer the system binaries we reason about; fall back to PATH only if
# they are absent.
hc_lsblk() {
  if [[ -x /usr/bin/lsblk ]]; then /usr/bin/lsblk "$@"; else lsblk "$@"; fi
}
hc_findmnt() {
  if [[ -x /usr/bin/findmnt ]]; then /usr/bin/findmnt "$@"; else findmnt "$@"; fi
}

hc_device_real() {
  local real
  real=$(readlink -f -- "${1:-}" 2>/dev/null || true)
  if [[ -n $real ]]; then printf '%s\n' "$real"; else printf '%s\n' "${1:-}"; fi
}

# hc_json_array <arg>... — one JSON array of strings ([] for no args).
hc_json_array() {
  if (( $# == 0 )); then
    printf '[]'
    return 0
  fi
  jq -Rn '$ARGS.positional' --args "$@"
}

hc_sync_file() {
  local f=$1
  sync -f -- "$f" 2>/dev/null || sync
}

# ---------------------------------------------------------------------------
# Image references
# ---------------------------------------------------------------------------

# hc_inspect_ref <ref> [auto|containers-storage|docker] — print a skopeo-readable ref.
# Auto rule: an unqualified name or localhost/127.0.0.1 is local container storage
# (that is where a bench image built with podman lives); anything with a registry
# hostname is docker://. Never guesses a localhost registry.
hc_inspect_ref() {
  local ref=${1:?} transport=${2:-auto}
  case $transport in
    auto|containers-storage|docker) ;;
    *) hc_die 2 E_TRANSPORT "unknown transport '$transport' (auto|containers-storage|docker)" ;;
  esac

  case $ref in
    containers-storage:*|docker://*|oci:*|docker-daemon:*) printf '%s\n' "$ref"; return 0 ;;
  esac
  case $transport in
    containers-storage) printf 'containers-storage:%s\n' "$ref"; return 0 ;;
    docker)             printf 'docker://%s\n' "$ref"; return 0 ;;
  esac

  if [[ $ref != */* ]]; then
    printf 'containers-storage:%s\n' "$ref"
    return 0
  fi
  case ${ref%%/*} in
    localhost|127.0.0.1|'[::1]') printf 'containers-storage:%s\n' "$ref" ;;
    *)                           printf 'docker://%s\n' "$ref" ;;
  esac
}

# hc_image_inspect_json <ref> [transport] — skopeo inspect JSON on stdout.
#
# stdout ONLY. skopeo writes its log to stderr — running as root it emits lines like
#   time="2026-10-21T00:44:54+11:00" level=warning msg="Not using native diff for overlay"
# — and merging those into the JSON stream makes jq fail with
#   jq: parse error: Invalid literal at line 1, column 6
# on a perfectly good image. That was a harness bug: the first sudo dry-run hit it. Keep
# stderr in its own file, surface one line as a warning, and never hand it to jq.
hc_image_inspect_json() {
  local ref=${1:?} transport=${2:-auto} iref out err
  iref=$(hc_inspect_ref "$ref" "$transport")
  err=$(mktemp) || { hc_warn "cannot create a temp file for skopeo stderr"; return 1; }
  if ! out=$(skopeo inspect --no-tags "$iref" 2>"$err"); then
    hc_warn "skopeo inspect failed for ${iref}: $(tail -n 1 "$err" 2>/dev/null)"
    rm -f "$err"
    return 1
  fi
  if [[ -s $err ]]; then
    # Visible, but on stderr where it cannot corrupt the JSON.
    hc_warn "skopeo: $(tail -n 1 "$err")"
  fi
  rm -f "$err"
  printf '%s\n' "$out"
}

hc_image_digest() {
  local ref=${1:?} transport=${2:-auto} json
  json=$(hc_image_inspect_json "$ref" "$transport") || return 1
  printf '%s' "$json" | jq -er '.Digest // empty'
}

hc_image_label() {
  local ref=${1:?} label=${2:?} transport=${3:-auto} json
  json=$(hc_image_inspect_json "$ref" "$transport") || return 1
  printf '%s' "$json" | jq -r --arg k "$label" '.Labels[$k] // empty'
}

# hc_image_labels_json <ref> [transport] — the whole label map as JSON.
hc_image_labels_json() {
  local ref=${1:?} transport=${2:-auto} json
  json=$(hc_image_inspect_json "$ref" "$transport") || return 1
  printf '%s' "$json" | jq -c '.Labels // {}'
}

# hc_pin_ref <ref> <sha256:...> — strip any tag or digest, append @digest, and keep a
# transport prefix when the reference already carries one (containers-storage:, docker://).
hc_pin_ref() {
  local ref=${1:?} digest=${2:?} prefix="" rest slashless
  case $ref in
    containers-storage:*|docker-daemon:*|oci:*|oci-archive:*|docker-archive:*)
      prefix=${ref%%:*}:; rest=${ref#*:} ;;
    docker://*)
      prefix="docker://"; rest=${ref#docker://} ;;
    *)
      rest=$ref ;;
  esac
  rest=${rest%%@*}
  slashless=${rest##*/}
  if [[ $slashless == *:* ]]; then
    rest=${rest%:*}
  fi
  printf '%s%s@%s\n' "$prefix" "$rest" "$digest"
}

# hc_pin_ref_for <ref> <digest> [transport] — pin the reference in the transport form
# bootc needs for --source-imgref (e.g. containers-storage:localhost/x@sha256:...).
hc_pin_ref_for() {
  local ref=${1:?} digest=${2:?} transport=${3:-auto} iref
  iref=$(hc_inspect_ref "$ref" "$transport")
  hc_pin_ref "$iref" "$digest"
}

# ---------------------------------------------------------------------------
# Block devices (read-only)
# ---------------------------------------------------------------------------

# hc_disk_name_for <device-or-mountpoint> — the parent whole-disk kernel name
# (sda, nvme0n1, ...) or empty if it cannot be resolved (tmpfs, overlay, ...).
hc_disk_name_for() {
  local path=${1:?} real name src
  real=$(hc_device_real "$path")
  name=${real##*/}
  if [[ -d /sys/block/$name ]]; then
    printf '%s\n' "$name"
    return 0
  fi
  if [[ -e /sys/class/block/$name ]]; then
    hc_lsblk -rsno NAME,TYPE -- "/dev/$name" 2>/dev/null \
      | awk '$2 == "disk" { print $1; exit }'
    return 0
  fi
  # A mountpoint or any path: resolve the backing source, then walk to its disk.
  src=$(hc_findmnt -no SOURCE --target "$path" 2>/dev/null | sed 's/\[.*//' || true)
  [[ -n $src && $src == /dev/* ]] || return 1
  hc_lsblk -rsno NAME,TYPE -- "$src" 2>/dev/null \
    | awk '$2 == "disk" { print $1; exit }'
}

# hc_device_class <device> — whole-disk | partition | other
hc_device_class() {
  local real name
  real=$(hc_device_real "${1:?}")
  name=${real##*/}
  if [[ -d /sys/class/block/$name/partition || -e /sys/class/block/$name/partition ]]; then
    printf 'partition\n'
  elif [[ -d /sys/block/$name ]]; then
    printf 'whole-disk\n'
  else
    printf 'other\n'
  fi
}

# hc_is_usb_or_removable <device> — print how it qualified, or nothing.
# A USB-attached SATA bridge reports removable=0, so transport ancestry is the primary
# witness and the removable flag is the fallback (that is exactly this bench's drive).
hc_usb_reason() {
  local real name sys rm tran
  real=$(hc_device_real "${1:?}")
  name=${real##*/}
  sys=$(readlink -f -- "/sys/block/$name" 2>/dev/null || true)
  if [[ $sys == */usb[0-9]*/* || $sys == */usb[0-9]* ]]; then
    printf 'sysfs-usb\n'
    return 0
  fi
  rm=$(cat "/sys/block/$name/removable" 2>/dev/null || true)
  if [[ $rm == 1 ]]; then
    printf 'sysfs-removable\n'
    return 0
  fi
  tran=$(hc_lsblk -dno TRAN -- "$real" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ $tran == usb ]]; then
    printf 'lsblk-tran-usb\n'
    return 0
  fi
  return 1
}

# hc_mountpoints_for_device <device> — "path<TAB>mountpoints" for the device and every
# descendant that is mounted or is swap. Empty output means nothing under it is in use.
hc_mountpoints_for_device() {
  local dev=${1:?} json
  json=$(hc_lsblk -J -o NAME,PATH,TYPE,MOUNTPOINTS,FSTYPE -- "$dev" 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r '
    .blockdevices[] | recurse(.children[]?)
    | select((((.mountpoints // []) | map(select(. != null and . != "")) | length) > 0)
             or .fstype == "swap")
    | [.path, ((.mountpoints // []) | join(",")), (.fstype // "")] | @tsv'
  # Swap that lsblk reports only as fstype is covered above; also ask the kernel.
  if [[ -r /proc/swaps ]]; then
    awk -v d="$dev" 'NR > 1 && $1 == d { printf "%s\t%s\t%s\n", d, "swap", "swap" }' /proc/swaps
  fi
}

hc_dev_size_bytes() {
  # -d: the whole device only. Without it lsblk also prints every child (partitions).
  hc_lsblk -dbno SIZE -- "${1:?}" 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

# The disks that must never be an install target or a boot target. The design names the
# internal disk; the mount walk catches it (and any future machine) even when the kernel
# names it differently.
hc_internal_disk_names() {
  local mnt d
  {
    printf '%s\n' nvme0n1
    for mnt in / /boot /boot/efi /home /var; do
      d=$(hc_disk_name_for "$mnt" 2>/dev/null || true)
      [[ -n $d ]] && printf '%s\n' "$d"
    done
  } | sort -u
}

# hc_internal_disk_for_device <device> — print the internal disk it belongs to, or fail.
hc_internal_disk_for_device() {
  local dev=${1:?} disk name internal
  disk=$(hc_disk_name_for "$dev" 2>/dev/null || true)
  name=$(basename "$(hc_device_real "$dev")")
  for internal in $(hc_internal_disk_names); do
    if [[ $disk == "$internal" || $name == "$internal" ]]; then
      printf '%s\n' "$internal"
      return 0
    fi
  done
  return 1
}

hc_dev_model() {
  hc_lsblk -dno MODEL -- "${1:?}" 2>/dev/null | sed 's/[[:space:]]*$//'
}

# hc_by_id_for <real device> — every /dev/disk/by-id symlink that resolves to it.
hc_by_id_for() {
  local real=${1:?} entry
  for entry in /dev/disk/by-id/*; do
    [[ -e $entry ]] || continue
    if [[ $(hc_device_real "$entry") == "$real" ]]; then
      printf '%s\n' "$entry"
    fi
  done
}

hc_fstype_for_path() {
  hc_findmnt -no FSTYPE --target "${1:?}" 2>/dev/null | head -n 1 || true
}

hc_fs_label_for_path() {
  local real
  real=$(hc_findmnt -no SOURCE --target "${1:?}" 2>/dev/null | sed 's/\[.*//' | head -n 1 || true)
  [[ -n $real ]] || return 0
  hc_lsblk -no LABEL -- "$real" 2>/dev/null | sed 's/[[:space:]]*$//' | head -n 1 || true
}

# ---------------------------------------------------------------------------
# Secure Boot
# ---------------------------------------------------------------------------

# hc_sb_state — enabled | disabled | not-efi | unknown
hc_sb_state() {
  local out
  if ! command -v mokutil >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  out=$(mokutil --sb-state 2>&1 || true)
  case $out in
    *'SecureBoot enabled'*)              printf 'enabled\n' ;;
    *'SecureBoot disabled'*)             printf 'disabled\n' ;;
    *'EFI variables are not supported'*) printf 'not-efi\n' ;;
    *)                                    printf 'unknown\n' ;;
  esac
}

# hc_sb_raw — the raw mokutil output, one line per line, for the record.
hc_sb_raw() {
  if command -v mokutil >/dev/null 2>&1; then
    mokutil --sb-state 2>&1 || true
  fi
}
