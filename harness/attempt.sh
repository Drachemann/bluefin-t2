#!/usr/bin/env bash
#
# harness/attempt.sh — writes attempt.json BEFORE the machine is powered on (R2-11).
#
# R2-11's three artifacts are monotone, each written by a different layer, so the
# *absence* of the next one localises the failure:
#
#   attempt.json  host harness, before power-on        proves the run existed
#   stages.log    the booted system, at sysinit and     proves the kernel+initramfs
#                 multi-user.target                      completed and userspace reached
#   result.json   the booted system, after the smoke    proves the run finished, and how
#                 test, then it powers off
#
# This is the first of the three. It is written by the host, onto the results stick,
# after the install and before the boot. A machine cannot report its own pre-Linux
# failure, so this record and the operator's photograph are the only evidence for the
# FAILED_BOOT class.
#
# The `photograph` field is part of the schema from the start and is null here.
# evaluate.sh refuses to close a FAILED_BOOT run until it is filled in.
#
# It writes nothing else and never writes to a disk. If install-receipt.json is present
# in the run directory (written by install-to-disk.sh --execute), the digest, KVER and
# target are taken from it and cross-checked; disagreement is an integrity error, not
# a value to overwrite.
#
# Exit codes: 0 written (or dry-run printed)
#             2 usage   3 guard refusal   4 resolution   5 environment   6 integrity

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/host-common.sh
source "$SCRIPT_DIR/lib/host-common.sh"

EXIT_USAGE=2
EXIT_GUARD=3
EXIT_RESOLVE=4
EXIT_ENV=5
EXIT_INTEGRITY=6

RUN_DIR=""
INTERACTIVE=0
RESULTS_ROOT=""
RUN_ID=""
IMAGE=""
IMAGE_TRANSPORT="auto"
DIGEST=""
PINNED=""
KVER=""
LABELS_JSON="{}"
TIMEOUT_DEFAULT=900
TIMEOUT_MAX=86400
TIMEOUT=$TIMEOUT_DEFAULT
PHOTOGRAPH=""
BOOT_TARGET=""
DRY_RUN=0
USB_REASON=""
TARGET_SIZE=""
TARGET_MODEL=""
TARGET_BY_ID=()
RECEIPT_SHA=""

usage() {
  cat <<'EOF'
usage: attempt.sh --run-dir DIR --boot-target /dev/sdX
                  [--image REF] [--digest sha256:...] [--kver KVER]
                  [--timeout SECONDS] [--photograph PATH]
                  [--transport auto|containers-storage|docker] [--dry-run]

or:    attempt.sh --results-root DIR --run-id ID --boot-target /dev/sdX [...]

 --interactive    record the attempt but do NOT ask the smoke test to power off.
                  Use it when the boot after the install is also the interactive
                  session: one boot, no power cycle (a T2 power loss costs a macOS
                  boot before Touch ID works again).

Writes runs/<run-id>/attempt.json onto the results stick BEFORE the machine powers on.

Required:
  --run-dir DIR        the run directory install-to-disk.sh reported
  --boot-target /dev/sdX   the disk that was installed and is about to be booted

Digest/KVER sources, in order:
  install-receipt.json in the run directory, then --digest / --kver, then the image
  labels. Disagreement between the receipt and an explicit flag is an error.

Options:
  --timeout SECONDS    boot-attempt timeout recorded in the attempt (default 900)
  --photograph PATH    a photograph taken before boot (rarely useful here; the
                       FAILED_BOOT photograph is supplied to evaluate.sh)
  --dry-run            validate and print the JSON; write nothing

Exit codes: 0 ok, 2 usage, 3 guard refusal, 4 resolution, 5 environment, 6 integrity.
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case $1 in
      --run-dir)      [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; RUN_DIR=$2; shift 2 ;;
      --results-root) [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; RESULTS_ROOT=$2; shift 2 ;;
      --run-id)       [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; RUN_ID=$2; shift 2 ;;
      --boot-target)  [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; BOOT_TARGET=$2; shift 2 ;;
      --image)        [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; IMAGE=$2; shift 2 ;;
      --transport)    [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; IMAGE_TRANSPORT=$2; shift 2 ;;
      --digest)       [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; DIGEST=$2; shift 2 ;;
      --kver)         [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; KVER=$2; shift 2 ;;
      --timeout)      [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; TIMEOUT=$2; shift 2 ;;
      --photograph)   [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; PHOTOGRAPH=$2; shift 2 ;;
      --interactive)  INTERACTIVE=1; shift ;;
      --dry-run)      DRY_RUN=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) printf 'error: E_USAGE: unknown argument: %s\n' "$1" >&2; usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
}

resolve_run_dir() {
  if [[ -n $RUN_DIR ]]; then
    [[ -d $RUN_DIR ]] || hc_die "$EXIT_GUARD" E_RUN_MISSING \
      "refusing to continue: run directory $RUN_DIR does not exist. install-to-disk.sh --execute creates it and prints the path."
    return 0
  fi
  if [[ -n $RESULTS_ROOT && -n $RUN_ID ]]; then
    RUN_DIR="$RESULTS_ROOT/runs/$RUN_ID"
    [[ -d $RUN_DIR ]] || hc_die "$EXIT_GUARD" E_RUN_MISSING \
      "refusing to continue: run directory $RUN_DIR does not exist."
    return 0
  fi
  hc_die "$EXIT_USAGE" E_NO_RUN \
    "refusing to continue: pass --run-dir from the install receipt output, or both --results-root and --run-id."
}

results_root_for_run() {
  local parent
  parent=$(dirname -- "$RUN_DIR")
  if [[ ${parent##*/} == runs ]]; then
    dirname -- "$parent"
  fi
}

validate_timeout() {
  [[ $TIMEOUT =~ ^[0-9]+$ ]] || hc_die "$EXIT_USAGE" E_BAD_TIMEOUT \
    "--timeout must be a whole number of seconds (got '$TIMEOUT')"
  (( TIMEOUT >= 1 && TIMEOUT <= TIMEOUT_MAX )) || hc_die "$EXIT_USAGE" E_BAD_TIMEOUT \
    "--timeout must be between 1 and $TIMEOUT_MAX seconds (got $TIMEOUT)"
}

guard_boot_target() {
  [[ -n $BOOT_TARGET ]] || hc_die "$EXIT_GUARD" E_NO_BOOT_TARGET \
    "refusing to continue: --boot-target is empty. There is no default boot target."
  [[ -e $BOOT_TARGET ]] || hc_die "$EXIT_GUARD" E_DEVICE_MISSING \
    "refusing $BOOT_TARGET: no such device"
  [[ -b $BOOT_TARGET ]] || hc_die "$EXIT_GUARD" E_NOT_BLOCK \
    "refusing $BOOT_TARGET: not a block device"

  local internal
  if internal=$(hc_internal_disk_for_device "$BOOT_TARGET"); then
    hc_die "$EXIT_GUARD" E_INTERNAL_DISK \
      "refusing $BOOT_TARGET: it belongs to $internal, the internal/root disk. A Tier 2 attempt boots the EXTERNAL disk; the internal disk is never a target."
  fi
  if ! USB_REASON=$(hc_usb_reason "$BOOT_TARGET"); then
    hc_die "$EXIT_GUARD" E_NOT_USB \
      "refusing $BOOT_TARGET: its parent is neither USB transport nor removable. The boot target must be the external USB drive that was installed."
  fi
}

# Fill DIGEST, KVER, IMAGE, PINNED, LABELS_JSON, and the target facts, cross-checking
# the install receipt when it exists.
resolve_run() {
  local receipt="$RUN_DIR/install-receipt.json"
  local r_digest="" r_ref="" r_pinned="" r_kver="" r_target="" r_size="" r_model="" r_external="" r_by_id="[]" r_labels="{}" r_sha=""
  local inspect_json="" inspect_ref=""

  if [[ -f $receipt ]]; then
    r_digest=$(jq -r '.image.digest // empty' "$receipt" 2>/dev/null || true)
    r_ref=$(jq -r '.image.ref // empty' "$receipt" 2>/dev/null || true)
    r_pinned=$(jq -r '.image.pinned_ref // empty' "$receipt" 2>/dev/null || true)
    r_kver=$(jq -r '.image.kver_label // empty' "$receipt" 2>/dev/null || true)
    r_target=$(jq -r '.target.realpath // empty' "$receipt" 2>/dev/null || true)
    r_size=$(jq -r '.target.size_bytes // empty' "$receipt" 2>/dev/null || true)
    r_model=$(jq -r '.target.model // empty' "$receipt" 2>/dev/null || true)
    r_external=$(jq -r '.target.external_proof // empty' "$receipt" 2>/dev/null || true)
    r_by_id=$(jq -c '.target.by_id // []' "$receipt" 2>/dev/null || printf '[]')
    r_labels=$(jq -c '.image.labels // {}' "$receipt" 2>/dev/null || printf '{}')
    r_sha=$(sha256sum -- "$receipt" | awk '{ print $1 }')
  else
    hc_warn "no install-receipt.json in $RUN_DIR; the attempt cannot be tied to an install"
  fi

  # Image reference.
  [[ -n $IMAGE ]] || IMAGE=${r_ref:-}
  [[ -n $IMAGE ]] || hc_die "$EXIT_INTEGRITY" E_NO_IMAGE_REF \
    "refusing to continue: no image reference (no --image and no receipt). The attempt must name what was installed."

  # Digest: explicit flag and receipt must agree.
  if [[ -n $DIGEST && -n $r_digest && $DIGEST != "$r_digest" ]]; then
    hc_die "$EXIT_INTEGRITY" E_DIGEST_MISMATCH \
      "--digest $DIGEST disagrees with the install receipt ($r_digest). One of them is the wrong run."
  fi
  [[ -n $DIGEST ]] || DIGEST=${r_digest:-}
  if [[ -z $DIGEST ]]; then
    DIGEST=$(hc_image_digest "$IMAGE" "$IMAGE_TRANSPORT" 2>/dev/null || true)
  fi
  [[ $DIGEST == sha256:* ]] || hc_die "$EXIT_RESOLVE" E_NO_DIGEST \
    "refusing to continue: cannot establish the image digest (no --digest, no receipt digest, and $IMAGE does not resolve). A Tier 2 run is digest-pinned or it is not a Tier 2 run."

  # Labels: receipt first, then a live inspect of the image.
  if [[ $r_labels == '{}' || -z $r_labels ]]; then
    if inspect_json=$(hc_image_inspect_json "$IMAGE" "$IMAGE_TRANSPORT" 2>/dev/null); then
      r_labels=$(printf '%s' "$inspect_json" | jq -c '.Labels // {}')
    else
      hc_warn "could not inspect labels for $IMAGE; recording an empty label map"
    fi
  fi
  LABELS_JSON=$r_labels

  # KVER: receipt label, then explicit flag, then the label map.
  local label_kver
  label_kver=$(printf '%s' "$LABELS_JSON" | jq -r '.["ostree.linux"] // empty')
  if [[ -n $KVER && -n $r_kver && $KVER != "$r_kver" ]]; then
    hc_die "$EXIT_INTEGRITY" E_KVER_MISMATCH \
      "--kver $KVER disagrees with the install receipt ($r_kver)."
  fi
  [[ -n $KVER ]] || KVER=${r_kver:-}
  [[ -n $KVER ]] || KVER="$label_kver"
  [[ -n $KVER ]] || hc_die "$EXIT_RESOLVE" E_NO_KVER \
    "refusing to continue: no KVER. The image carries no ostree.linux label; pass --kver <uname -r of the image>."

  # Pinned reference, transport-aware.
  if [[ -n $r_pinned ]]; then
    PINNED=$r_pinned
  else
    PINNED=$(hc_pin_ref_for "$IMAGE" "$DIGEST" "$IMAGE_TRANSPORT")
  fi

  # Boot target must be the one that was installed.
  local want got
  want=$(hc_device_real "$BOOT_TARGET")
  if [[ -n $r_target ]]; then
    got=$(hc_device_real "$r_target")
    if [[ $want != "$got" ]]; then
      hc_die "$EXIT_INTEGRITY" E_TARGET_MISMATCH \
        "--boot-target $BOOT_TARGET resolves to $want, but the install receipt recorded $got. This attempt would be filed against the wrong disk."
    fi
  fi
  TARGET_SIZE=$(hc_dev_size_bytes "$BOOT_TARGET" 2>/dev/null || printf '%s' "${r_size:-}")
  TARGET_MODEL=$(hc_dev_model "$BOOT_TARGET" 2>/dev/null || printf '%s' "${r_model:-}")
  [[ -n $TARGET_MODEL ]] || TARGET_MODEL=${r_model:-}
  mapfile -t TARGET_BY_ID < <(hc_by_id_for "$want")
  if (( ${#TARGET_BY_ID[@]} == 0 )) && [[ $r_by_id != '[]' ]]; then
    mapfile -t TARGET_BY_ID < <(printf '%s' "$r_by_id" | jq -r '.[]')
  fi
  RECEIPT_SHA=$r_sha
}

guard_photograph() {
  [[ -n $PHOTOGRAPH ]] || return 0
  [[ -f $PHOTOGRAPH ]] || hc_die "$EXIT_GUARD" E_PHOTOGRAPH_MISSING \
    "refusing to continue: --photograph $PHOTOGRAPH is not a regular file"
  [[ -s $PHOTOGRAPH ]] || hc_die "$EXIT_GUARD" E_PHOTOGRAPH_EMPTY \
    "refusing to continue: --photograph $PHOTOGRAPH is empty"
}

write_current_pointer() {
  local root=$1 id=$2 tmp
  [[ -n $root ]] || return 0
  [[ -d $root ]] || return 0
  tmp="$root/.CURRENT.tmp.$$"
  printf '%s\n' "$id" > "$tmp"
  hc_sync_file "$tmp"
  mv -- "$tmp" "$root/CURRENT"
  hc_sync_file "$root"
}

build_attempt_json() {
  local size_json=null photograph_json=null by_id_json
  [[ -n ${TARGET_SIZE:-} ]] && size_json=$TARGET_SIZE
  if [[ -n $PHOTOGRAPH ]]; then
    photograph_json=$(jq -Rn --arg p "$PHOTOGRAPH" '$p')
  fi
  by_id_json=$(hc_json_array "${TARGET_BY_ID[@]}")

  jq -n \
    --argjson schema 1 \
    --arg kind "attempt" \
    --arg run_id "$(basename -- "$RUN_DIR")" \
    --arg run_dir "$RUN_DIR" \
    --arg created_at "$(hc_now)" \
    --arg image_ref "$IMAGE" \
    --arg image_digest "$DIGEST" \
    --arg pinned_ref "$PINNED" \
    --arg kver "$KVER" \
    --argjson labels "$LABELS_JSON" \
    --arg boot_device "$BOOT_TARGET" \
    --arg boot_real "$(hc_device_real "$BOOT_TARGET")" \
    --arg boot_model "$TARGET_MODEL" \
    --argjson boot_size "$size_json" \
    --argjson boot_by_id "$by_id_json" \
    --arg boot_external "$USB_REASON" \
    --arg sb_state "$(hc_sb_state)" \
    --arg sb_raw "$(hc_sb_raw)" \
    --argjson timeout "$TIMEOUT" \
    --argjson photograph "$photograph_json" \
    --arg operator "$(id -un)" \
    --arg hostname "$(hostname)" \
    --arg host_kernel "$(uname -r)" \
    --arg results_root "$(results_root_for_run)" \
    --arg receipt_sha256 "$RECEIPT_SHA" \
    '{
       schema: $schema,
       kind: $kind,
       run_id: $run_id,
       run_dir: $run_dir,
       created_at: $created_at,
       image: {
         ref: $image_ref,
         digest: $image_digest,
         pinned_ref: $pinned_ref,
         kver: $kver,
         labels: $labels
       },
       boot_target: {
         device: $boot_device,
         realpath: $boot_real,
         model: $boot_model,
         size_bytes: $boot_size,
         by_id: $boot_by_id,
         external_proof: $boot_external
       },
       secure_boot: {
         state: $sb_state,
         raw: ($sb_raw | split("\n") | map(select(length > 0))),
         source: "mokutil --sb-state"
       },
       timeout_s: $timeout,
       photograph: $photograph,
       artifact_expectations: {
         stages: "stages.log",
         result: "result.json",
         stages_expected: ["sysinit.target", "multi-user.target"]
       },
       operator: { user: $operator, hostname: $hostname, host_kernel: $host_kernel },
       results: { root: $results_root },
       install_receipt_sha256: (if $receipt_sha256 == "" then null else $receipt_sha256 end)
     }'
}

main() {
  parse_args "$@"
  resolve_run_dir
  validate_timeout
  guard_boot_target
  hc_require_cmd jq
  resolve_run
  guard_photograph

  local attempt="$RUN_DIR/attempt.json"
  if [[ -e $attempt ]]; then
    hc_die "$EXIT_INTEGRITY" E_ATTEMPT_EXISTS \
      "refusing to overwrite $attempt. An attempt is evidence; start a new run (new run id) instead."
  fi

  local json
  json=$(build_attempt_json)

  printf '%s\n' "$json" | jq . >/dev/null 2>&1 || hc_die "$EXIT_INTEGRITY" E_BAD_JSON \
    "the attempt JSON failed to generate; nothing was written"

  if (( DRY_RUN == 1 )); then
    printf '%s\n' "$json"
    hc_log "dry-run: nothing was written"
    return 0
  fi

  local tmp="$RUN_DIR/.attempt.XXXXXX"
  tmp=$(mktemp "$tmp")
  printf '%s\n' "$json" > "$tmp"
  hc_sync_file "$tmp"
  mv -- "$tmp" "$attempt"
  # A scored run asks the smoke test to power off. --interactive does not: the same boot
  # goes on to the interactive session, and a T2 power loss costs a macOS boot before
  # Touch ID works again.
  if (( INTERACTIVE == 1 )); then
    hc_log "interactive: no POWEROFF marker; the smoke test will stay up"
  else
    : > "$RUN_DIR/POWEROFF"
    hc_sync_file "$RUN_DIR/POWEROFF"
  fi
  hc_sync_file "$RUN_DIR"
  write_current_pointer "$(results_root_for_run)" "$(basename -- "$RUN_DIR")"

  printf 'attempt recorded: %s\n' "$attempt"
  printf '  run id:       %s\n' "$(basename -- "$RUN_DIR")"
  printf '  image:        %s@%s\n' "$IMAGE" "$DIGEST"
  printf '  kver:         %s\n' "$KVER"
  printf '  boot target:  %s (%s, %s)\n' "$BOOT_TARGET" "$TARGET_MODEL" "$USB_REASON"
  printf '  secure boot:  %s\n' "$(hc_sb_state)"
  printf '  timeout:      %ss\n' "$TIMEOUT"
  if [[ -n $PHOTOGRAPH ]]; then
    printf '  photograph:   %s\n' "$PHOTOGRAPH"
  else
    printf '  photograph:   null (required only if the next boot dies before sysinit)\n'
  fi
  printf '\nNEXT: power the machine off now. At the chime hold Option and boot the\n'
  printf '      external disk. The smoke test powers it off when it finishes.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
