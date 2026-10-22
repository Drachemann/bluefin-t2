#!/usr/bin/env bash
#
# harness/install-to-disk.sh — guarded wrapper around `bootc install to-disk` for the
# Tier 2 bench run (design of record §9 "Tier 2", docs/designs/kait2en-bluefin-v2.md).
#
# WHAT IT DOES
#   Resolves the bench image to a digest, refuses any target that is not an external
#   whole disk, and — only with --execute AND an explicit CONFIRM=<device> token AND
#   root — runs the design's pinned invocation:
#
#     podman run --privileged --pid=host --rm -it \
#       -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
#       quay.io/fedora/fedora-bootc:44 bootc install to-disk \
#       --source-imgref <image>@sha256:<digest> <device>
#
#   It then writes runs/<run-id>/install-receipt.json to the results root. It never
#   writes attempt.json — that is attempt.sh, because R2-11 needs it written before
#   the machine is powered on and after the install has finished.
#
# WHAT IT REFUSES (each with a greppable NAMED ERROR)
#   E_INTERNAL_DISK      the internal disk, or any partition of it, however named:
#                        /dev/nvme0n1, the disk backing /, /boot, /boot/efi or /home
#   E_PARTITION          a partition instead of a whole disk
#   E_NOT_WHOLE_DISK     a dm/loop/other block device, not a whole disk
#   E_NOT_USB            a parent that is neither USB transport nor removable
#   E_TARGET_EMPTY       the device reports 0 bytes (it dropped out, or has no media)
#   E_TARGET_TOO_SMALL   the device is smaller than the image's root filesystem
#   E_MOUNTED            the disk or anything under it is mounted, or is swap
#   E_CONFIRM_MISSING    CONFIRM is unset or empty
#   E_CONFIRM_MISMATCH   CONFIRM resolves to a different device than --device
#   E_NO_IMAGE           an empty image reference
#   E_NO_DEVICE          a missing --device (there is no default disk)
#   E_NO_RESULTS_ROOT    a missing --results-root
#   E_DIGEST_UNRESOLVED  the image cannot be pinned to a digest
#   E_RESULTS_ON_TARGET  results root on the same disk as the install target
#   E_RESULTS_UNKNOWN    cannot tell which disk the results root is on
#   E_RESULTS_MISSING / E_RESULTS_NOT_WRITABLE  the results directory is not usable
#   E_RESULTS_LABEL      (execute) results stick does not carry the K2B-HIL label the
#                        booted system mounts by
#   E_RESULTS_NOT_REMOVABLE (execute) results root is not on removable/USB storage, so
#                        the booted test system could not write to it
#   E_NOT_ROOT           --execute without root (rootful podman is required to write a
#                        block device; this script never invokes sudo itself)
#   E_BOOTC_UNPINNED     the bootc container image could not be pinned to a digest
#   E_RUN_EXISTS         the run directory already exists (runs are never reused)
#
# IT CANNOT RUN BY ITSELF. There is no default device, no default mode and no
# auto-execution: run with no arguments and it prints usage and exits 2.
#
# Exit codes: 0 ok (plan printed, or install succeeded)
#             2 usage   3 guard refusal   4 image resolution
#             5 environment   6 integrity   7 install failed
#
# This script is part of the bench harness, not the release image. It is safe to
# source (for selftest.sh): main() runs only when executed directly.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/host-common.sh
source "$SCRIPT_DIR/lib/host-common.sh"

BOOTC_IMAGE_DEFAULT="quay.io/fedora/fedora-bootc:44"
RESULTS_LABEL_DEFAULT="K2B-HIL"
# bootc needs an explicit root filesystem when the image ships no
# /usr/lib/bootc/install/*.toml — which this one does not. btrfs matches Bluefin's root.
ROOT_FS="${ROOT_FS:-btrfs}"

EXIT_USAGE=2
EXIT_GUARD=3
EXIT_RESOLVE=4
EXIT_ENV=5
EXIT_INTEGRITY=6
EXIT_INSTALL=7

MODE=""
IMAGE=""
IMAGE_TRANSPORT="auto"
DEVICE=""
RESULTS_ROOT=""
RUN_ID=""
BOOTC_IMAGE="$BOOTC_IMAGE_DEFAULT"
ALLOW_FLOATING_BOOTC=0

# Filled in by the guards.
DIGEST=""
PINNED=""
KVER_LABEL=""
LABELS_JSON="{}"
RDISK=""
RESULTS_LABEL=""
RESULTS_FSTYPE=""
USB_REASON=""
SIZE_BYTES=""
IMAGE_SIZE_BYTES=""
PINNED_BOOTC=""
BOOTC_PINNED=0
RUN_DIR=""
STARTED_AT=""

usage() {
  cat <<'EOF'
usage: install-to-disk.sh --image REF --device /dev/sdX --results-root DIR
                          (--dry-run | --execute)
                          [--run-id ID] [--transport auto|containers-storage|docker]
                          [--bootc-image REF] [--allow-floating-bootc]

Installs the bench image to an EXTERNAL disk with bootc install to-disk.

Required:
  --image REF          bench image, e.g. localhost/bluefin-t2-bench:0.1.0
  --device /dev/sdX    whole external disk. No default. Partitions are refused.
  --results-root DIR   mounted results stick (label K2B-HIL for --execute)

Mode (exactly one):
  --dry-run            print the plan and the resolved digest; write nothing, run nothing
  --execute            run the install. Requires root and CONFIRM=<resolved device>.

Confirmation:
  CONFIRM=/dev/sdX     must resolve to the same device as --device, or nothing runs.

Options:
  --run-id ID          reuse a chosen run id (default: generated from UTC time)
  --transport T        how skopeo reaches --image (default: auto — localhost/ and
                       unqualified names are local container storage)
  --bootc-image REF    container providing bootc (default: quay.io/fedora/fedora-bootc:44)
  --root-fs FS         target root filesystem: btrfs (default), ext4 or xfs
  --allow-floating-bootc  permit --execute when the bootc image cannot be pinned

Exit codes: 0 ok, 2 usage, 3 guard refusal, 4 image resolution, 5 environment,
            6 integrity, 7 install failed.
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case $1 in
      --image)        [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; IMAGE=$2; shift 2 ;;
      --device)       [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; DEVICE=$2; shift 2 ;;
      --results-root) [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; RESULTS_ROOT=$2; shift 2 ;;
      --run-id)       [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; RUN_ID=$2; shift 2 ;;
      --transport)    [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; IMAGE_TRANSPORT=$2; shift 2 ;;
      --bootc-image)  [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; BOOTC_IMAGE=$2; shift 2 ;;
      --allow-floating-bootc) ALLOW_FLOATING_BOOTC=1; shift ;;
      --root-fs)      [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; ROOT_FS=$2; shift 2 ;;
      --dry-run)
        [[ -z $MODE || $MODE == dry-run ]] || { usage >&2; exit "$EXIT_USAGE"; }
        MODE=dry-run; shift ;;
      --execute)
        [[ -z $MODE || $MODE == execute ]] || { usage >&2; exit "$EXIT_USAGE"; }
        MODE=execute; shift ;;
      -h|--help) usage; exit 0 ;;
      *) printf 'error: E_USAGE: unknown argument: %s\n' "$1" >&2; usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
  case $ROOT_FS in
    btrfs|ext4|xfs) : ;;
    *) printf 'error: E_USAGE: --root-fs must be btrfs, ext4 or xfs (got %s)\n' "$ROOT_FS" >&2; exit "$EXIT_USAGE" ;;
  esac
}

# ---------------------------------------------------------------------------
# Guards. Each prints nothing and returns 0, or exits with a named error.
# ---------------------------------------------------------------------------

guard_device() {
  [[ -e $DEVICE ]] || hc_die "$EXIT_GUARD" E_DEVICE_MISSING \
    "refusing $DEVICE: no such device"
  [[ -b $DEVICE ]] || hc_die "$EXIT_GUARD" E_NOT_BLOCK \
    "refusing $DEVICE: not a block device"
}

# Shared with attempt.sh: one implementation decides what "the internal disk" means.
guard_not_internal() {
  local internal
  if internal=$(hc_internal_disk_for_device "$DEVICE"); then
    hc_die "$EXIT_GUARD" E_INTERNAL_DISK \
      "refusing $DEVICE: it belongs to $internal, the internal/root disk (the running system). The internal disk is never an install target."
  fi
}

guard_whole_disk() {
  case $(hc_device_class "$DEVICE") in
    whole-disk) : ;;
    partition)
      hc_die "$EXIT_GUARD" E_PARTITION \
        "refusing $DEVICE: it is a partition. bootc install to-disk claims a whole disk; pass the disk (for example /dev/sda)."
      ;;
    *)
      hc_die "$EXIT_GUARD" E_NOT_WHOLE_DISK \
        "refusing $DEVICE: not a whole-disk block device (dm/loop/other)."
      ;;
  esac
}

guard_external() {
  if ! USB_REASON=$(hc_usb_reason "$DEVICE"); then
    hc_die "$EXIT_GUARD" E_NOT_USB \
      "refusing $DEVICE: its parent is neither USB transport nor removable (lsblk TRAN=$(hc_lsblk -dno TRAN -- "$DEVICE" 2>/dev/null | tr -d '[:space:]')). The target must be an external USB drive."
  fi
}

guard_not_mounted() {
  local used
  used=$(hc_mountpoints_for_device "$DEVICE" 2>/dev/null || true)
  if [[ -n $used ]]; then
    hc_die "$EXIT_GUARD" E_MOUNTED \
      "refusing $DEVICE: the disk or something under it is mounted or in use:
$(printf '%s\n' "$used" | awk -F'\t' '{ printf "    %s  %s  %s\n", $1, $2, $3 }')"
  fi
}

guard_confirm() {
  local want got
  want=$(hc_device_real "$DEVICE")
  if [[ -z ${CONFIRM:-} ]]; then
    hc_die "$EXIT_GUARD" E_CONFIRM_MISSING \
      "refusing to continue: CONFIRM is not set. The exact token is:
    CONFIRM=$want"
  fi
  got=$(hc_device_real "$CONFIRM")
  if [[ $got != "$want" ]]; then
    hc_die "$EXIT_GUARD" E_CONFIRM_MISMATCH \
      "refusing to continue: CONFIRM=$CONFIRM resolves to $got, but --device resolves to $want."
  fi
}

guard_results_root() {
  [[ -n $RESULTS_ROOT ]] || hc_die "$EXIT_GUARD" E_NO_RESULTS_ROOT \
    "refusing to continue: --results-root is required (the mounted results stick; results never share a device with the install target)."
  [[ -d $RESULTS_ROOT ]] || hc_die "$EXIT_GUARD" E_RESULTS_MISSING \
    "refusing to continue: --results-root $RESULTS_ROOT is not a directory. Mount the K2B-HIL stick first."
  [[ -w $RESULTS_ROOT ]] || hc_die "$EXIT_GUARD" E_RESULTS_NOT_WRITABLE \
    "refusing to continue: --results-root $RESULTS_ROOT is not writable."

  RDISK=$(hc_disk_name_for "$RESULTS_ROOT" 2>/dev/null || true)
  [[ -n $RDISK ]] || hc_die "$EXIT_GUARD" E_RESULTS_UNKNOWN \
    "refusing to continue: cannot tell which disk $RESULTS_ROOT lives on, so separateness from the target cannot be proven."
  if [[ $RDISK == "$(hc_disk_name_for "$DEVICE" 2>/dev/null || true)" ]]; then
    hc_die "$EXIT_GUARD" E_RESULTS_ON_TARGET \
      "refusing to continue: results root $RESULTS_ROOT is on $RDISK, the same disk as the install target $DEVICE. bootc install to-disk repartitions it; results must live on a separate device."
  fi

  RESULTS_LABEL=$(hc_fs_label_for_path "$RESULTS_ROOT" || true)
  RESULTS_FSTYPE=$(hc_fstype_for_path "$RESULTS_ROOT" || true)

  if [[ $MODE == execute ]]; then
    if [[ $RESULTS_LABEL != "$RESULTS_LABEL_DEFAULT" ]]; then
      hc_die "$EXIT_GUARD" E_RESULTS_LABEL \
        "refusing to continue: results root $RESULTS_ROOT has filesystem label '${RESULTS_LABEL:-<none>}', but the booted test system mounts the results stick by label $RESULTS_LABEL_DEFAULT. Relabel the stick (fatlabel) or pass the right device."
    fi
    if ! hc_usb_reason "/dev/$RDISK" >/dev/null; then
      hc_die "$EXIT_GUARD" E_RESULTS_NOT_REMOVABLE \
        "refusing to continue: results root $RESULTS_ROOT is on $RDISK, which is not removable/USB. The booted test system must be able to mount it; it cannot mount the internal disk."
    fi
  else
    [[ $RESULTS_LABEL == "$RESULTS_LABEL_DEFAULT" ]] || hc_warn \
      "dry-run: --execute would refuse: results label '${RESULTS_LABEL:-<none>}' is not $RESULTS_LABEL_DEFAULT"
    [[ $RESULTS_FSTYPE == vfat ]] || hc_warn \
      "dry-run: results filesystem is '${RESULTS_FSTYPE:-unknown}', not vfat (fat32 is the designed medium)"
  fi
}

# The target must be able to hold the image. A device reporting 0 bytes has dropped out
# (the kernel logs "detected capacity change ... to 0") and bootc would fail partway
# through writing it. A device smaller than the image's uncompressed root filesystem
# cannot be installed to at all. Both are cheap to prove before anything is written.
guard_capacity() {
  local bytes=${SIZE_BYTES:-0} need=${IMAGE_SIZE_BYTES:-0}
  local need_gib=$(( ${IMAGE_SIZE_BYTES:-0} / 1073741824 )) tight_gib
  if [[ ! $bytes =~ ^[0-9]+$ ]] || (( bytes == 0 )); then
    hc_die "$EXIT_GUARD" E_TARGET_EMPTY \
      "refusing $DEVICE: it reports 0 bytes (lsblk SIZE='$(hc_lsblk -dno SIZE -- "$DEVICE" 2>/dev/null | tr -d '[:space:]')'). The device has dropped out or has no media — re-seat it, then check: lsblk -b -d $DEVICE"
  fi
  if (( need > 0 && bytes < need )); then
    hc_die "$EXIT_GUARD" E_TARGET_TOO_SMALL \
      "refusing $DEVICE: ${bytes} bytes is smaller than the image's root filesystem (${need} bytes, about ${need_gib} GiB). The target must be at least the image size."
  fi
  if (( need > 0 && bytes < need + need / 5 )); then
    tight_gib=$(( bytes / 1073741824 ))
    hc_warn "$DEVICE is tight: ${tight_gib} GiB for a ${need_gib} GiB image plus /var. It will install, but leave little room to grow."
  fi
}

guard_image() {
  local json err
  [[ -n $IMAGE ]] || hc_die "$EXIT_GUARD" E_NO_IMAGE \
    "refusing to continue: --image is empty. Pass the bench image reference."

  if ! json=$(hc_image_inspect_json "$IMAGE" "$IMAGE_TRANSPORT"); then
    err="cannot inspect $IMAGE"
    if [[ $(hc_inspect_ref "$IMAGE" "$IMAGE_TRANSPORT") == containers-storage:* ]]; then
      err="$err
    The reference was read as LOCAL container storage. If the bench image was built
    rootless it is not visible to rootful podman. Move it into root storage first:
      podman save -o /tmp/bench.tar localhost/<name>:<tag>
      sudo podman load -i /tmp/bench.tar"
    fi
    hc_die "$EXIT_RESOLVE" E_DIGEST_UNRESOLVED "refusing to continue: $err"
  fi

  DIGEST=$(printf '%s' "$json" | jq -r '.Digest // empty')
  [[ $DIGEST == sha256:* ]] || hc_die "$EXIT_RESOLVE" E_DIGEST_UNRESOLVED \
    "cannot resolve $IMAGE to a digest (got '${DIGEST:-<none>}')"
  LABELS_JSON=$(printf '%s' "$json" | jq -c '.Labels // {}')
  IMAGE_SIZE_BYTES=$(printf '%s' "$json" | jq -r '.size // .Size // 0')
  [[ $IMAGE_SIZE_BYTES =~ ^[0-9]+$ ]] || IMAGE_SIZE_BYTES=0
  KVER_LABEL=$(printf '%s' "$json" | jq -r '.Labels["ostree.linux"] // empty')
  # bootc's --source-imgref takes a containers/image reference, so the transport prefix
  # is part of the pin: containers-storage:localhost/x@sha256:... for a local bench image.
  PINNED=$(hc_pin_ref_for "$IMAGE" "$DIGEST" "$IMAGE_TRANSPORT")
}

guard_execute_environment() {
  (( EUID == 0 )) || hc_die "$EXIT_ENV" E_NOT_ROOT \
    "--execute needs root: rootful podman is required to write a block device. This script never calls sudo itself. Re-run it as:
    sudo $0 --execute --image $IMAGE --device ${DEVICE:-/dev/sdX} --results-root $RESULTS_ROOT"
}

resolve_bootc_image() {
  local ref=$1 candidate
  candidate=$(podman image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$ref" 2>/dev/null || true)
  if [[ -n $candidate ]]; then
    PINNED_BOOTC=$(hc_pin_ref "$ref" "${candidate##*@}")
    BOOTC_PINNED=1
    return 0
  fi
  candidate=$(hc_image_digest "$ref" docker 2>/dev/null || true)
  if [[ -n $candidate ]]; then
    PINNED_BOOTC=$(hc_pin_ref "$ref" "$candidate")
    BOOTC_PINNED=1
    return 0
  fi
  PINNED_BOOTC="$ref"
  BOOTC_PINNED=0
}

build_podman_command() {
  PODMAN_CMD=(podman run --privileged --pid=host --rm)
  if [[ -t 0 && -t 1 ]]; then
    PODMAN_CMD+=(-it)
  else
    PODMAN_CMD+=(-i)
  fi
  PODMAN_CMD+=(
    -v /dev:/dev
    -v /var/lib/containers:/var/lib/containers
    "$PINNED_BOOTC"
    bootc install to-disk --filesystem "$ROOT_FS" --wipe --source-imgref "$PINNED" "$DEVICE"
  )
}

print_plan() {
  local mode_label
  if [[ $MODE == execute ]]; then mode_label="EXECUTE"; else mode_label="DRY-RUN"; fi
  printf '%s\n' "bluefin-t2 Tier 2 bench install — $mode_label"
  printf '  %-18s %s\n' 'image ref:'    "$IMAGE"
  printf '  %-18s %s\n' 'image digest:' "$DIGEST"
  printf '  %-18s %s\n' 'pinned source:' "$PINNED"
  if [[ -n $KVER_LABEL ]]; then
    printf '  %-18s %s\n' 'kver label:' "$KVER_LABEL"
  else
    printf '  %-18s %s\n' 'kver label:' '<missing ostree.linux — attempt.sh will require --kver>'
  fi
  printf '  %-18s %s\n' 'target device:' "$DEVICE ($(hc_device_real "$DEVICE"))"
  printf '  %-18s %s\n' 'device class:'  "$(hc_device_class "$DEVICE")"
  printf '  %-18s %s\n' 'external proof:' "$USB_REASON"
  printf '  %-18s %s\n' 'transport:' "$(hc_lsblk -dno TRAN -- "$DEVICE" 2>/dev/null | tr -d '[:space:]')"
  printf '  %-18s %s\n' 'size/model:'   "${SIZE_BYTES:-?} bytes / $(hc_dev_model "$DEVICE")"
  printf '  %-18s %s\n' 'mounted parts:' 'none (checked)'
  printf '  %-18s %s\n' 'results root:'  "$RESULTS_ROOT (label '${RESULTS_LABEL:-<none>}', $RESULTS_FSTYPE, disk $RDISK)"
  printf '  %-18s %s\n' 'run id:'        "$RUN_ID"
  printf '  %-18s %s\n' 'run dir:'       "$RUN_DIR"
  if (( BOOTC_PINNED == 1 )); then
    printf '  %-18s %s\n' 'bootc image:' "$PINNED_BOOTC (pinned)"
  else
    printf '  %-18s %s\n' 'bootc image:' "$PINNED_BOOTC (floating)"
  fi
  printf '  %-18s %s\n' 'command:' "${PODMAN_CMD[*]@Q}"
}

write_receipt() {
  local receipt="$RUN_DIR/install-receipt.json" tmp size_json by_id_json
  tmp=$(mktemp "$RUN_DIR/.install-receipt.XXXXXX")
  size_json=null
  [[ -n ${SIZE_BYTES:-} ]] && size_json=$SIZE_BYTES
  by_id_json=$(hc_json_array "${BY_ID[@]}")

  jq -n \
    --argjson schema 1 \
    --arg kind "install-receipt" \
    --arg run_id "$RUN_ID" \
    --arg created_at "$(hc_now)" \
    --arg hostname "$(hostname)" \
    --arg host_kernel "$(uname -r)" \
    --arg host_user "$(id -un)" \
    --arg image_ref "$IMAGE" \
    --arg image_digest "$DIGEST" \
    --arg pinned_ref "$PINNED" \
    --arg kver_label "$KVER_LABEL" \
    --argjson labels "$LABELS_JSON" \
    --arg device "$DEVICE" \
    --arg device_real "$(hc_device_real "$DEVICE")" \
    --arg device_model "$(hc_dev_model "$DEVICE")" \
    --argjson device_size_bytes "$size_json" \
    --argjson by_id "$by_id_json" \
    --arg transport "$(hc_lsblk -dno TRAN -- "$DEVICE" 2>/dev/null | tr -d '[:space:]')" \
    --arg usb_reason "$USB_REASON" \
    --arg results_root "$RESULTS_ROOT" \
    --arg results_disk "$RDISK" \
    --arg results_label "$RESULTS_LABEL" \
    --arg results_fstype "$RESULTS_FSTYPE" \
    --arg run_dir "$RUN_DIR" \
    --arg bootc_ref "$PINNED_BOOTC" \
    --argjson bootc_pinned "$BOOTC_PINNED" \
    --arg command "${PODMAN_CMD[*]@Q}" \
    --arg started_at "$STARTED_AT" \
    --arg finished_at "$(hc_now)" \
    '{
       schema: $schema,
       kind: $kind,
       run_id: $run_id,
       created_at: $created_at,
       host: { hostname: $hostname, kernel: $host_kernel, user: $host_user },
       image: { ref: $image_ref, digest: $image_digest, pinned_ref: $pinned_ref, kver_label: $kver_label, labels: $labels },
       target: { device: $device, realpath: $device_real, model: $device_model, size_bytes: $device_size_bytes, by_id: $by_id, transport: $transport, external_proof: $usb_reason },
       bootc_image: { ref: $bootc_ref, pinned: $bootc_pinned },
       results: { root: $results_root, disk: $results_disk, label: $results_label, fstype: $results_fstype, run_dir: $run_dir },
       command: $command,
       confirmed: true,
       started_at: $started_at,
       finished_at: $finished_at
     }' > "$tmp"
  hc_sync_file "$tmp"
  mv -- "$tmp" "$receipt"
  hc_sync_file "$RUN_DIR"
}

main() {
  parse_args "$@"

  case $MODE in
    dry-run|execute) : ;;
    *) usage >&2; exit "$EXIT_USAGE" ;;
  esac

  # Presence first: there is no default disk, no default image and no default results
  # location, so an omitted argument can never turn into a write.
  [[ -n $IMAGE ]]        || hc_die "$EXIT_GUARD" E_NO_IMAGE \
    "refusing to continue: --image is empty. Pass the bench image reference."
  [[ -n $DEVICE ]]       || hc_die "$EXIT_GUARD" E_NO_DEVICE \
    "refusing to continue: --device is empty. There is no default disk; name the external whole disk explicitly."
  [[ -n $RESULTS_ROOT ]] || hc_die "$EXIT_GUARD" E_NO_RESULTS_ROOT \
    "refusing to continue: --results-root is empty. Results must live on a separate device."

  hc_require_cmd jq skopeo
  if [[ $MODE == execute ]]; then
    guard_execute_environment
    hc_require_cmd podman
  fi

  guard_device
  guard_not_internal
  guard_whole_disk
  guard_external
  SIZE_BYTES=$(hc_dev_size_bytes "$DEVICE" 2>/dev/null || true)
  guard_not_mounted
  guard_confirm
  guard_results_root
  guard_image
  guard_capacity

  resolve_bootc_image "$BOOTC_IMAGE"
  if (( BOOTC_PINNED == 0 )); then
    if [[ $MODE == execute && $ALLOW_FLOATING_BOOTC -ne 1 ]]; then
      hc_die "$EXIT_INTEGRITY" E_BOOTC_UNPINNED \
        "refusing --execute: the bootc image $BOOTC_IMAGE could not be pinned to a digest, so the tool that writes the disk would be whatever the tag points at. Pull it (podman pull $BOOTC_IMAGE) or pass --allow-floating-bootc to accept that."
    fi
    hc_warn "bootc image $BOOTC_IMAGE is not digest-pinned (dry-run continues; --execute would refuse)"
  fi

  build_podman_command
  [[ -n $RUN_ID ]] || RUN_ID=$(hc_run_id)
  RUN_DIR="$RESULTS_ROOT/runs/$RUN_ID"
  if [[ -n $KVER_LABEL ]]; then
    :
  else
    hc_warn "image has no ostree.linux label; attempt.sh will require --kver for this run"
  fi

  if [[ $MODE == execute && -e $RUN_DIR ]]; then
    hc_die "$EXIT_INTEGRITY" E_RUN_EXISTS \
      "refusing --execute: run directory $RUN_DIR already exists. Pass a new --run-id; a run is never reused."
  fi

  mapfile -t BY_ID < <(hc_by_id_for "$(hc_device_real "$DEVICE")")

  print_plan

  if [[ $MODE == dry-run ]]; then
    printf '\ndry-run: nothing was written, no container was run, no disk was touched.\n'
    return 0
  fi

  mkdir -p "$RUN_DIR"
  STARTED_AT=$(hc_now)
  # bootc's --wipe clears partition tables and whole-disk signatures, but NOT a filesystem
  # signature sitting where a new partition will land. mkfs.btrfs is then invoked without
  # -f and refuses: "appears to contain an existing filesystem (type=btrfs, label=root)".
  # That is what a second attempt hits after a first attempt got as far as mkfs. Clear the
  # signatures on every existing partition and on the disk before handing it to bootc.
  # Safe here: the device guards have already run and CONFIRM has matched this device.
  hc_log "clearing existing filesystem and partition-table signatures on $DEVICE"
  if command -v wipefs >/dev/null 2>&1; then
    while IFS= read -r part; do
      [[ -n $part ]] || continue
      if ! wipefs -a "$part" >/dev/null 2>&1; then
        hc_warn "wipefs could not clear $part (continuing; bootc may refuse it)"
      fi
    done < <(hc_lsblk -lnpo NAME "$DEVICE" 2>/dev/null | tail -n +2)
    if ! wipefs -a "$DEVICE" >/dev/null 2>&1; then
      hc_warn "wipefs could not clear $DEVICE (continuing; bootc's --wipe may still work)"
    fi
  else
    hc_warn "wipefs not found; a leftover filesystem signature will make bootc's mkfs refuse"
  fi

  hc_log "executing: ${PODMAN_CMD[*]@Q}"
  if ! "${PODMAN_CMD[@]}"; then
    hc_die "$EXIT_INSTALL" E_INSTALL_FAILED \
      "bootc install to-disk failed. No receipt was written to $RUN_DIR. The pinned source was:
    $PINNED
Fix the cause and re-run; a re-run without --run-id starts a fresh run directory.
Do not write attempt.json for an install that did not finish."
  fi

  write_receipt
  printf '\ninstalled: %s -> %s\n' "$PINNED" "$DEVICE"
  printf 'receipt:   %s\n' "$RUN_DIR/install-receipt.json"
  printf 'next:      pre-place the firmware payload on the target ESP, then run attempt.sh\n'
  printf '           BOTH before powering the machine off. Boot the external disk with Option at boot.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
