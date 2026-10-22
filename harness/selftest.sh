#!/usr/bin/env bash
#
# harness/selftest.sh — proves the harness itself before a bench slot is spent on it.
#
# Everything here is synthetic: fixture run directories in a temp dir, fixture TOMLs,
# the real block devices on this machine only as *subjects of refusal* (read-only
# checks), and the boot-side scripts against a fake results stick via HIL_SKIP_MOUNT.
# It never runs bootc, never mounts anything, never writes to a block device and never
# powers off anything.
#
# It covers:
#   * evaluate.sh: all four R2-11 branches, the FAILED_BOOT photograph refusal and
#     close, and the integrity gates (digest/KVER/assertion self-consistency)
#   * install-to-disk.sh: every named refusal, the no-auto-execution rule, and one
#     allowed --dry-run plan
#   * attempt.sh: refusal, digest/KVER resolution, the written schema, no overwrite
#   * the boot-side layer: stage line format, models.d parsing (python3 and awk
#     fallback), and a full stage-log + smoke-test run against a fake stick
#   * systemd units: systemd-analyze verify in a staged --root
#
# Exit 0 only if every case passed or was explicitly skipped.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/host-common.sh
source "$ROOT/lib/host-common.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bluefin-t2-hil-selftest.XXXXXX")
RESULTS_DEMO=""
cleanup() {
  rm -rf "$TMP"
  if [[ -n ${RESULTS_DEMO:-} ]]; then
    rm -rf "$RESULTS_DEMO"
  fi
}
trap cleanup EXIT

PASS=0
FAIL=0
SKIP=0
declare -a FAILURES=()
LAST_OUT=""
DIGEST_A="sha256:$(printf 'a%.0s' {1..64})"
DIGEST_B="sha256:$(printf 'b%.0s' {1..64})"
KVER_A="7.2.5-200.fc44.x86_64"
KVER_B="7.2.11-200.fc44.x86_64"

ok()   { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad()  {
  FAIL=$((FAIL + 1)); FAILURES+=("$1")
  printf 'FAIL  %s\n' "$1"
  shift
  (( $# == 0 )) || printf '        %s\n' "$*"
}
skip() { SKIP=$((SKIP + 1)); printf 'skip  %s (%s)\n' "$1" "$2"; }

run_rc() {
  local name=$1 expected=$2
  shift 2
  local rc=0 out=""
  if out=$("$@" 2>&1); then rc=0; else rc=$?; fi
  LAST_OUT=$out
  if [[ $rc == "$expected" ]]; then
    ok "$name"
  else
    bad "$name" "expected rc=$expected, got rc=$rc; tail: $(printf '%s' "$out" | tail -n 3 | tr '\n' '|')"
  fi
}

expect_in_output() {
  local name=$1 pattern=$2
  if printf '%s' "$LAST_OUT" | grep -q -- "$pattern"; then
    ok "$name"
  else
    bad "$name" "output did not contain '$pattern': $(printf '%s' "$LAST_OUT" | tail -n 2 | tr '\n' '|')"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

new_run() { mkdir -p "$TMP/runs/$1"; printf '%s\n' "$TMP/runs/$1"; }

make_attempt() {
  local dir=$1 digest=${2:-$DIGEST_A} kver=${3:-$KVER_A} photograph=${4:-null}
  jq -n --arg d "$digest" --arg k "$kver" --argjson p "$photograph" '{
    schema: 1, kind: "attempt", run_id: "test", created_at: "2026-10-20T00:00:00Z",
    image: { ref: "localhost/bluefin-t2-bench:test", digest: $d, kver: $k,
             pinned_ref: ("containers-storage:localhost/bluefin-t2-bench@" + $d) },
    boot_target: { device: "/dev/sda", model: "MacBookPro16,2" },
    secure_boot: { state: "disabled" },
    timeout_s: 900,
    photograph: $p
  }' > "$dir/attempt.json"
}

make_stages() {
  local dir=$1 mode=$2
  case $mode in
    both)
      printf 'stage=sysinit.target time=2026-10-20T00:00:10Z uptime=10 boot=b\n' > "$dir/stages.log"
      printf 'stage=multi-user.target time=2026-10-20T00:00:40Z uptime=40 boot=b\n' >> "$dir/stages.log"
      ;;
    early)
      printf 'stage=sysinit.target time=2026-10-20T00:00:10Z uptime=10 boot=b\n' > "$dir/stages.log"
      ;;
    multi)
      printf 'stage=multi-user.target time=2026-10-20T00:00:40Z uptime=40 boot=b\n' > "$dir/stages.log"
      ;;
    retried)
      # A retried boot appends its own pair. The run's artefact is the last boot.
      printf 'stage=sysinit.target time=2026-10-20T00:00:10Z uptime=10 boot=a\n' > "$dir/stages.log"
      printf 'stage=multi-user.target time=2026-10-20T00:00:40Z uptime=40 boot=a\n' >> "$dir/stages.log"
      printf 'stage=sysinit.target time=2026-10-20T00:05:10Z uptime=10 boot=b\n' >> "$dir/stages.log"
      printf 'stage=multi-user.target time=2026-10-20T00:05:40Z uptime=40 boot=b\n' >> "$dir/stages.log"
      ;;
    retried-early)
      printf 'stage=sysinit.target time=2026-10-20T00:00:10Z uptime=10 boot=a\n' > "$dir/stages.log"
      printf 'stage=multi-user.target time=2026-10-20T00:00:40Z uptime=40 boot=a\n' >> "$dir/stages.log"
      printf 'stage=sysinit.target time=2026-10-20T00:05:10Z uptime=10 boot=b\n' >> "$dir/stages.log"
      ;;
    empty) : > "$dir/stages.log" ;;
    garbage) printf 'this is not a stage line\n' > "$dir/stages.log" ;;
  esac
}

# make_result <dir> <status> <digest> <kver> <assertions_ok:0|1>
make_result() {
  local dir=$1 status=$2 digest=$3 kver=$4 all_ok=$5 failed_json
  if [[ $all_ok == 1 ]]; then
    failed_json='[]'
  else
    failed_json='["wifi"]'
  fi
  jq -n --arg s "$status" --arg d "$digest" --arg k "$kver" \
    --argjson ok "$all_ok" --argjson failed "$failed_json" '{
    schema: 1, kind: "result", status: $s, booted_kver: $k, image_digest: $d,
    assertions: {
      modules: { ok: ($ok == 1), missing: [] },
      firmware: { ok: ($ok == 1), matches: [] },
      wifi: { ok: ($ok == 1), device: "wlan0" },
      systemd_failed: { ok: ($ok == 1), units: [] }
    },
    failed_assertions: $failed
  }' > "$dir/result.json"
}

# ---------------------------------------------------------------------------
# evaluate.sh — R2-11's four branches and the strictness around them
# ---------------------------------------------------------------------------

echo '== evaluate.sh =='

d=$(new_run pass); make_attempt "$d"; make_stages "$d" both; make_result "$d" pass "$DIGEST_A" "$KVER_A" 1
run_rc "pass: 2 stages + result pass" 0 "$ROOT/evaluate.sh" --run-dir "$d"
if [[ -f "$d/verdict.json" ]] && [[ $(jq -r '.outcome' "$d/verdict.json") == PASS ]]; then
  ok "pass: verdict.json written with outcome PASS"
else
  bad "pass: verdict.json written with outcome PASS"
fi

d=$(new_run fail); make_attempt "$d"; make_stages "$d" both; make_result "$d" fail "$DIGEST_A" "$KVER_A" 0
run_rc "fail: 2 stages + result fail" 1 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run userspace-1line); make_attempt "$d"; make_stages "$d" early
run_rc "FAILED_USERSPACE: 1 stage line, no result" 2 "$ROOT/evaluate.sh" --run-dir "$d"
if jq -e '.stages.reached_stage == "sysinit.target"' "$d/verdict.json" >/dev/null 2>&1; then
  ok "FAILED_USERSPACE: verdict names sysinit.target"
else
  bad "FAILED_USERSPACE: verdict names sysinit.target"
fi

d=$(new_run userspace-2lines); make_attempt "$d"; make_stages "$d" both
run_rc "FAILED_USERSPACE: 2 lines, no result (R2-11 silent; documented decision)" 2 "$ROOT/evaluate.sh" --run-dir "$d"
if jq -e '.reason == "smoke-test-did-not-complete"' "$d/verdict.json" >/dev/null 2>&1; then
  ok "FAILED_USERSPACE: reason smoke-test-did-not-complete"
else
  bad "FAILED_USERSPACE: reason smoke-test-did-not-complete"
fi

d=$(new_run boot-unclosed); make_attempt "$d"
run_rc "FAILED_BOOT without photograph refuses to close" 20 "$ROOT/evaluate.sh" --run-dir "$d"
if [[ ! -f "$d/verdict.json" ]]; then
  ok "FAILED_BOOT refusal wrote no verdict"
else
  bad "FAILED_BOOT refusal wrote no verdict"
fi

d=$(new_run boot-closed); make_attempt "$d"
printf 'pretend-photo-bytes\n' > "$TMP/photo.jpg"
run_rc "FAILED_BOOT with photograph closes" 3 "$ROOT/evaluate.sh" --run-dir "$d" --photograph "$TMP/photo.jpg"
if [[ -f "$d/photograph.jpg" ]] && jq -e '.photograph == "photograph.jpg"' "$d/attempt.json" >/dev/null 2>&1; then
  ok "FAILED_BOOT: photograph copied into the run and recorded in attempt.json"
else
  bad "FAILED_BOOT: photograph copied into the run and recorded in attempt.json"
fi
if jq -e '.photograph == "photograph.jpg"' "$d/verdict.json" >/dev/null 2>&1 \
   && jq -e '(.photograph_sha256 | length) == 64' "$d/attempt.json" >/dev/null 2>&1; then
  ok "FAILED_BOOT: verdict names the photograph and attempt.json carries its hash"
else
  bad "FAILED_BOOT: verdict names the photograph and attempt.json carries its hash"
fi

d=$(new_run no-attempt)
run_rc "HARNESS_ERROR: no attempt.json" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run bad-attempt); printf '{"kind":"nonsense"}\n' > "$d/attempt.json"
run_rc "HARNESS_ERROR: attempt.json not an attempt" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run digest-mismatch); make_attempt "$d"; make_stages "$d" both; make_result "$d" pass "$DIGEST_B" "$KVER_A" 1
run_rc "HARNESS_ERROR: booted digest disagrees with attempt" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run kver-mismatch); make_attempt "$d"; make_stages "$d" both; make_result "$d" pass "$DIGEST_A" "$KVER_B" 1
run_rc "HARNESS_ERROR: booted KVER disagrees with attempt" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run stages-empty); make_attempt "$d"; make_stages "$d" empty
run_rc "HARNESS_ERROR: empty stages.log" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run stages-garbage); make_attempt "$d"; make_stages "$d" garbage
run_rc "HARNESS_ERROR: unparseable stages.log" 4 "$ROOT/evaluate.sh" --run-dir "$d"

# A retried boot (two boots in one stages.log) is evaluated as the last boot, not read
# as an inverted order. The 2026-10-21 bench run produced exactly this shape.
d=$(new_run retried-boots); make_attempt "$d"; make_stages "$d" retried; make_result "$d" pass "$DIGEST_A" "$KVER_A" 1
run_rc "retried boot: last boot evaluated, PASS" 0 "$ROOT/evaluate.sh" --run-dir "$d"
if jq -e '.stages.boots == 2 and .stages.boot_id == "b"' "$d/verdict.json" >/dev/null 2>&1; then
  ok "retried boot: verdict records two boots and the last boot id"
else
  bad "retried boot: verdict records two boots and the last boot id"
fi

# The last boot is the evidence: if it only reached sysinit while an earlier boot reached
# multi-user, the artefacts contradict each other and the run is not a pass.
d=$(new_run retried-early); make_attempt "$d"; make_stages "$d" retried-early; make_result "$d" pass "$DIGEST_A" "$KVER_A" 1
run_rc "retried boot: last boot stopped at sysinit is a harness error" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run stages-multi-only); make_attempt "$d"; make_stages "$d" multi
run_rc "HARNESS_ERROR: multi-user line without sysinit" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run result-before-userspace); make_attempt "$d"; make_stages "$d" early; make_result "$d" pass "$DIGEST_A" "$KVER_A" 1
run_rc "HARNESS_ERROR: result.json without a multi-user stage line" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run pass-inconsistent); make_attempt "$d"; make_stages "$d" both; make_result "$d" pass "$DIGEST_A" "$KVER_A" 0
run_rc "HARNESS_ERROR: pass with a failed assertion" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run fail-inconsistent); make_attempt "$d"; make_stages "$d" both; make_result "$d" fail "$DIGEST_A" "$KVER_A" 1
run_rc "HARNESS_ERROR: fail with every assertion true" 4 "$ROOT/evaluate.sh" --run-dir "$d"

d=$(new_run dryrun); make_attempt "$d"; make_stages "$d" both; make_result "$d" pass "$DIGEST_A" "$KVER_A" 1
run_rc "dry-run: pass classified" 0 "$ROOT/evaluate.sh" --run-dir "$d" --dry-run
if [[ ! -f "$d/verdict.json" ]]; then
  ok "dry-run: no verdict written"
else
  bad "dry-run: no verdict written"
fi

run_rc "HARNESS_ERROR: no run directory" 4 "$ROOT/evaluate.sh" --run-dir "$TMP/runs/does-not-exist"
run_rc "usage: no arguments" 4 "$ROOT/evaluate.sh"

# results-root + CURRENT resolution
printf 'pass\n' > "$TMP/CURRENT"
run_rc "CURRENT pointer resolves the run" 0 "$ROOT/evaluate.sh" --results-root "$TMP" --dry-run

# ---------------------------------------------------------------------------
# install-to-disk.sh — refusals, no auto-execution, one allowed dry-run plan
# ---------------------------------------------------------------------------

echo
echo '== install-to-disk.sh =='

# A real external whole disk that is unmounted and reports a non-zero size. The results
# disk IS mounted during a real bench run, so hardcoding /dev/sda makes this suite fail on
# the layout the bench actually has — which is exactly what happened. Discover it; if none
# qualifies (e.g. the only stick is broken), the few cases that need one are skipped with
# a reason instead of reported as harness failures.
FIXTURE_DEV=""
for _d in /dev/sd?; do
  [[ -b $_d ]] || continue
  [[ "$(/usr/bin/lsblk -dno TRAN -- "$_d" 2>/dev/null | tr -d '[:space:]')" == usb ]] || continue
  _size=$(/usr/bin/lsblk -dno SIZE -- "$_d" 2>/dev/null | tr -d '[:space:]')
  [[ -z $_size || $_size == 0B ]] && continue
  [[ -n "$(/usr/bin/lsblk -no MOUNTPOINT -- "$_d" 2>/dev/null | tr -d '[:space:]')" ]] && continue
  FIXTURE_DEV=$_d
  break
done
FIXTURE_PART=""
for _d in /dev/sd?; do
  [[ -b $_d ]] || continue
  [[ "$(/usr/bin/lsblk -dno TRAN -- "$_d" 2>/dev/null | tr -d '[:space:]')" == usb ]] || continue
  for _p in ${_d}?*; do
    if [[ -b $_p ]]; then FIXTURE_PART=$_p; break 2; fi
  done
done

run_rc "no arguments prints usage (rc 2), nothing runs" 2 "$ROOT/install-to-disk.sh"
run_rc "empty image refused" 3 "$ROOT/install-to-disk.sh" --dry-run --image '' --device /dev/sda --results-root "$TMP"
expect_in_output "empty image names E_NO_IMAGE" E_NO_IMAGE
run_rc "internal disk refused" 3 "$ROOT/install-to-disk.sh" --dry-run --image localhost/x:1 --device /dev/nvme0n1 --results-root "$TMP"
expect_in_output "internal disk names E_INTERNAL_DISK" E_INTERNAL_DISK
run_rc "partition of the internal disk refused" 3 "$ROOT/install-to-disk.sh" --dry-run --image localhost/x:1 --device /dev/nvme0n1p3 --results-root "$TMP"
expect_in_output "internal partition names E_INTERNAL_DISK" E_INTERNAL_DISK
if [[ -n $FIXTURE_PART ]]; then
  run_rc "external partition refused" 3 "$ROOT/install-to-disk.sh" --dry-run --image localhost/x:1 --device "$FIXTURE_PART" --results-root "$TMP"
  expect_in_output "external partition names E_PARTITION" E_PARTITION
else
  skip "external partition refused" "no external disk currently has a partition"
fi
run_rc "non-USB disk refused (zram)" 3 "$ROOT/install-to-disk.sh" --dry-run --image localhost/x:1 --device /dev/zram0 --results-root "$TMP"
expect_in_output "zram names E_NOT_USB" E_NOT_USB
run_rc "missing device refused" 3 "$ROOT/install-to-disk.sh" --dry-run --image localhost/x:1 --device /dev/does-not-exist --results-root "$TMP"
expect_in_output "missing device names E_DEVICE_MISSING" E_DEVICE_MISSING
if [[ -n $FIXTURE_DEV ]]; then
  run_rc "missing CONFIRM refused" 3 env -u CONFIRM "$ROOT/install-to-disk.sh" --dry-run --image localhost/x:1 --device "$FIXTURE_DEV" --results-root "$TMP"
  expect_in_output "missing CONFIRM names E_CONFIRM_MISSING" E_CONFIRM_MISSING
  run_rc "wrong CONFIRM refused" 3 env CONFIRM=/dev/nvme0n1 "$ROOT/install-to-disk.sh" --dry-run --image localhost/x:1 --device "$FIXTURE_DEV" --results-root "$TMP"
  expect_in_output "wrong CONFIRM names E_CONFIRM_MISMATCH" E_CONFIRM_MISMATCH
else
  skip "missing CONFIRM refused" "no unmounted external whole disk; the CONFIRM guard cannot be reached"
  skip "wrong CONFIRM refused" "no unmounted external whole disk; the CONFIRM guard cannot be reached"
fi
run_rc "unknown argument refused" 2 "$ROOT/install-to-disk.sh" --dry-run --image localhost/x:1 --device /dev/sda --results-root "$TMP" --nonsense
run_rc "both --dry-run and --execute refused" 2 "$ROOT/install-to-disk.sh" --dry-run --execute --image localhost/x:1 --device /dev/sda --results-root "$TMP"

if (( EUID == 0 )); then
  skip "--execute without root refused" "running as root, so the guard cannot be exercised"
else
  if [[ -n $FIXTURE_DEV ]]; then
    run_rc "--execute without root refused" 5 env CONFIRM="$FIXTURE_DEV" "$ROOT/install-to-disk.sh" --execute --image localhost/x:1 --device "$FIXTURE_DEV" --results-root "$TMP"
    expect_in_output "--execute without root names E_NOT_ROOT" E_NOT_ROOT
  else
    skip "--execute without root refused" "no unmounted external whole disk available"
  fi
fi

# Sourced-function cases: the guards that need a fixture (mounted / same-disk / label).
run_rc "mounted target refused (fixture)" 3 bash -c '
  set -euo pipefail
  source "$1/install-to-disk.sh"
  DEVICE=/dev/sda; RESULTS_ROOT=/tmp; MODE=dry-run
  hc_mountpoints_for_device() { printf "/dev/sda1\t/mnt\t ext4\n"; }
  guard_not_mounted
' _ "$ROOT"
expect_in_output "mounted fixture names E_MOUNTED" E_MOUNTED

run_rc "results on the target disk refused (fixture)" 3 bash -c '
  set -euo pipefail
  source "$1/install-to-disk.sh"
  DEVICE=/dev/sda; RESULTS_ROOT=/tmp; MODE=dry-run
  hc_disk_name_for() { printf "sda\n"; }
  guard_results_root
' _ "$ROOT"
expect_in_output "same-disk results names E_RESULTS_ON_TARGET" E_RESULTS_ON_TARGET

run_rc "wrong results label refused under --execute (fixture)" 3 bash -c '
  set -euo pipefail
  source "$1/install-to-disk.sh"
  DEVICE=/dev/sda; RESULTS_ROOT=/tmp; MODE=execute
  hc_disk_name_for() { case "$1" in /dev/sda) printf "sda\n" ;; *) printf "nvme0n1\n" ;; esac; }
  hc_fs_label_for_path() { printf "NOTK2B\n"; }
  hc_fstype_for_path() { printf "vfat\n"; }
  guard_results_root
' _ "$ROOT"
expect_in_output "wrong label names E_RESULTS_LABEL" E_RESULTS_LABEL

# One allowed plan: a real local image, a real external disk, a results root on a
# different disk. Dry-run only; nothing is written and podman is not invoked.
if [[ ! -d /var/tmp ]]; then
  skip "allowed --dry-run plan" "/var/tmp is absent"
elif ! skopeo inspect --no-tags containers-storage:localhost/bluefin-t2-proof:7.2.5 >/dev/null 2>&1; then
  skip "allowed --dry-run plan" "localhost/bluefin-t2-proof:7.2.5 is not in local container storage"
elif [[ -z $FIXTURE_DEV ]]; then
  skip "allowed --dry-run plan" "no unmounted external whole disk with non-zero size"
else
  RESULTS_DEMO=$(mktemp -d /var/tmp/bluefin-t2-hil-selftest.XXXXXX)
  run_rc "allowed --dry-run plan (no writes, no podman)" 0 \
    env CONFIRM="$FIXTURE_DEV" "$ROOT/install-to-disk.sh" --dry-run \
      --image localhost/bluefin-t2-proof:7.2.5 \
      --bootc-image localhost/bluefin-t2-proof:7.2.5 \
      --device "$FIXTURE_DEV" --results-root "$RESULTS_DEMO"
  expect_in_output "plan resolves a sha256 digest" 'image digest: *sha256:'
  expect_in_output "plan pins the source with its transport" 'pinned source: *containers-storage:'
  expect_in_output "plan says nothing was touched" 'dry-run: nothing was written'
  if [[ -z $(find "$RESULTS_DEMO" -mindepth 1 -print -quit 2>/dev/null) ]]; then
    ok "dry-run wrote nothing into the results root"
  else
    bad "dry-run wrote nothing into the results root"
  fi
fi

# ---------------------------------------------------------------------------
# attempt.sh
# ---------------------------------------------------------------------------

echo
echo '== attempt.sh =='

d=$(new_run attempt-no-receipt)
run_rc "missing run directory refused" 3 "$ROOT/attempt.sh" --run-dir "$TMP/runs/nope" --boot-target /dev/sda --dry-run
run_rc "missing boot target refused" 3 "$ROOT/attempt.sh" --run-dir "$d" --dry-run --image localhost/x:1 --digest "$DIGEST_A" --kver "$KVER_A"
run_rc "internal boot target refused" 3 "$ROOT/attempt.sh" --run-dir "$d" --boot-target /dev/nvme0n1 --dry-run --image localhost/x:1 --digest "$DIGEST_A" --kver "$KVER_A"
expect_in_output "internal boot target names E_INTERNAL_DISK" E_INTERNAL_DISK
run_rc "attempt without a digest refused" 4 "$ROOT/attempt.sh" --run-dir "$d" --boot-target /dev/sda --dry-run --image localhost/x:1 --kver "$KVER_A"
expect_in_output "no digest names E_NO_DIGEST" E_NO_DIGEST

run_rc "dry-run prints JSON and writes nothing" 0 "$ROOT/attempt.sh" --run-dir "$d" --boot-target /dev/sda --dry-run --image localhost/x:1 --digest "$DIGEST_A" --kver "$KVER_A"
if [[ ! -f "$d/attempt.json" ]]; then
  ok "dry-run wrote no attempt.json"
else
  bad "dry-run wrote no attempt.json"
fi
printf '%s\n' "$LAST_OUT" | sed -n '/^{/,/^}$/p' > "$TMP/attempt-dryrun.json"
if jq -e '.kind == "attempt" and .photograph == null' "$TMP/attempt-dryrun.json" >/dev/null 2>&1; then
  ok "dry-run JSON has kind=attempt and photograph=null"
else
  bad "dry-run JSON has kind=attempt and photograph=null"
fi

run_rc "attempt written" 0 "$ROOT/attempt.sh" --run-dir "$d" --boot-target /dev/sda --image localhost/x:1 --digest "$DIGEST_A" --kver "$KVER_A"
if jq -e '.kind == "attempt" and .image.digest == $d and .image.kver == $k and (.photograph == null)
          and (.timeout_s == 900) and (.secure_boot.state | type == "string")
          and (.boot_target.device == "/dev/sda")' --arg d "$DIGEST_A" --arg k "$KVER_A" "$d/attempt.json" >/dev/null 2>&1; then
  ok "attempt.json carries digest, kver, timeout, SB state, target, photograph"
else
  bad "attempt.json carries digest, kver, timeout, SB state, target, photograph"
fi
run_rc "attempt.json is never overwritten" 6 "$ROOT/attempt.sh" --run-dir "$d" --boot-target /dev/sda --image localhost/x:1 --digest "$DIGEST_A" --kver "$KVER_A"

# ---------------------------------------------------------------------------
# Boot-side layer
# ---------------------------------------------------------------------------

echo
echo '== boot side (fake stick) =='

STICK="$TMP/stick"
RUN="$STICK/runs/run-1"
mkdir -p "$RUN" "$TMP/models"
printf 'run-1\n' > "$STICK/CURRENT"
make_attempt "$RUN"
LOADED_MOD=$(awk 'NR == 1 { print $1 }' /proc/modules | tr '-' '_')
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null || printf 'unknown')
cat > "$TMP/models/$MODEL.toml" <<EOF
expected_loaded = ["$LOADED_MOD"]
expected_unbound = []
expected_absent = ["bluefin_t2_hil_absent_probe"]
EOF
cp "$TMP/models/$MODEL.toml" "$TMP/models/awk-schema.toml"

run_rc "stage-log early appends a line" 0 env HIL_SKIP_MOUNT=1 HIL_RESULTS_ROOT="$STICK" "$ROOT/rootfs/usr/libexec/bluefin-t2-hil/stage-log" early
run_rc "stage-log userspace appends a line" 0 env HIL_SKIP_MOUNT=1 HIL_RESULTS_ROOT="$STICK" "$ROOT/rootfs/usr/libexec/bluefin-t2-hil/stage-log" userspace
if [[ $(wc -l < "$RUN/stages.log") == 2 ]] \
   && grep -q '^stage=sysinit.target time=.* uptime=.* boot=' "$RUN/stages.log" \
   && grep -q '^stage=multi-user.target ' "$RUN/stages.log"; then
  ok "stages.log holds two fsync-able stage lines in order"
else
  bad "stages.log holds two fsync-able stage lines in order"
fi

run_rc "smoke-test writes result.json against the fake stick" 0 env HIL_SKIP_MOUNT=1 HIL_RESULTS_ROOT="$STICK" \
  HIL_MODELS_DIR="$TMP/models" HIL_SETTLE_S=0 HIL_WIFI_WAIT_S=0 \
  "$ROOT/rootfs/usr/libexec/bluefin-t2-hil/smoke-test"
if jq -e '.kind == "result"
          and (.status == "pass" or .status == "fail")
          and (.booted_kver == $k)
          and (.assertions | has("modules") and has("firmware") and has("wifi") and has("systemd_failed"))
          and (.observed.suspend_tested == false)' --arg k "$(uname -r)" "$RUN/result.json" >/dev/null 2>&1; then
  ok "result.json carries the four assertions and the booted KVER"
else
  bad "result.json carries the four assertions and the booted KVER"
fi

# The booted host has no bootc, so the digest is absent: the evaluator must refuse the
# run as evidence rather than reporting a pass. This is the digest-pinned gate working.
run_rc "result without a recorded digest is HARNESS_ERROR" 4 "$ROOT/evaluate.sh" --run-dir "$RUN"
expect_in_output "missing digest names digest-unrecorded" digest-unrecorded

# models.d parsers, both paths
cat > "$TMP/models/schema.toml" <<'EOF'
expected_loaded  = ["t2bce_dma", "t2hid"]
expected_unbound = ["hid_t2magicmouse"]
expected_absent  = ["t2gmux", "unmeasured"]
EOF
out=$(bash -c 'source "$1"; hil_models_category_python "$2" expected_loaded' _ "$ROOT/rootfs/usr/libexec/bluefin-t2-hil/lib.sh" "$TMP/models/schema.toml" || true)
if [[ $(printf '%s\n' "$out" | grep -c .) == 2 ]] && printf '%s' "$out" | grep -qx t2bce_dma; then
  ok "models.d parsed via python3/tomllib"
else
  bad "models.d parsed via python3/tomllib" "got: $out"
fi
out=$(bash -c 'source "$1"; hil_models_category_awk "$2" expected_absent' _ "$ROOT/rootfs/usr/libexec/bluefin-t2-hil/lib.sh" "$TMP/models/schema.toml" || true)
if printf '%s' "$out" | grep -qx t2gmux && printf '%s' "$out" | grep -qx unmeasured; then
  ok "models.d parsed via the awk fallback"
else
  bad "models.d parsed via the awk fallback" "got: $out"
fi
# A TOML formatter (or a human) may split the array across lines; the awk fallback
# must still read it, because the image may have no python3.
cat > "$TMP/models/multiline.toml" <<'EOF'
expected_loaded = [
  "t2bce_dma",
  "t2hid",
]
EOF
out=$(bash -c 'source "$1"; hil_models_category_awk "$2" expected_loaded' _ "$ROOT/rootfs/usr/libexec/bluefin-t2-hil/lib.sh" "$TMP/models/multiline.toml" || true)
if printf '%s' "$out" | grep -qx t2bce_dma && printf '%s' "$out" | grep -qx t2hid; then
  ok "models.d parsed via the awk fallback across multiple lines"
else
  bad "models.d parsed via the awk fallback across multiple lines" "got: $out"
fi

run_rc "models.d missing category returns 4" 4 bash -c 'source "$1"; hil_models_category_awk "$2" expected_missing' _ "$ROOT/rootfs/usr/libexec/bluefin-t2-hil/lib.sh" "$TMP/models/schema.toml"
run_rc "stage line format is exact" 0 bash -c 'source "$1"; [[ $(hil_stage_line sysinit.target T U B) == "stage=sysinit.target time=T uptime=U boot=B" ]]' _ "$ROOT/rootfs/usr/libexec/bluefin-t2-hil/lib.sh"

# ---------------------------------------------------------------------------
# Units
# ---------------------------------------------------------------------------

echo
echo '== units =='

if ! command -v systemd-analyze >/dev/null 2>&1; then
  skip "systemd-analyze verify" "systemd-analyze is not installed"
else
  VROOT="$TMP/verifyroot"
  mkdir -p "$VROOT/usr/lib/systemd" "$VROOT/usr/libexec" "$VROOT/etc/systemd/system" "$VROOT/run" "$VROOT/var"
  cp -a /usr/lib/systemd/system "$VROOT/usr/lib/systemd/system" 2>/dev/null || true
  cp -a "$ROOT/rootfs/usr/libexec/bluefin-t2-hil" "$VROOT/usr/libexec/"
  cp -a "$ROOT/rootfs/usr/lib/systemd/system/." "$VROOT/usr/lib/systemd/system/"
  cp -a "$ROOT/rootfs/etc/systemd/system/." "$VROOT/etc/systemd/system/"
  cp -a "$ROOT/rootfs/usr/lib/systemd/system-preset" "$VROOT/usr/lib/systemd/system-preset"
  printf 'x\n' > "$VROOT/etc/machine-id"
  if systemd-analyze verify --root="$VROOT" \
       bluefin-t2-hil-early.service bluefin-t2-hil-userspace.service bluefin-t2-hil-test.service \
       >/dev/null 2>"$TMP/verify.err"; then
    ok "systemd-analyze verify: three harness units"
  else
    # dracut units in the copied host tree are masked symlinks to /dev/null; ignore
    # only those, any other diagnostic is ours.
    if grep -v 'dracut' "$TMP/verify.err" | grep -q .; then
      bad "systemd-analyze verify: three harness units" "$(grep -v dracut "$TMP/verify.err" | head -n 3 | tr '\n' '|')"
    else
      ok "systemd-analyze verify: three harness units (only unrelated dracut noise)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "passed: $PASS   failed: $FAIL   skipped: $SKIP"
if (( FAIL > 0 )); then
  printf 'failures:\n'
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
