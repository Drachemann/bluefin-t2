#!/usr/bin/env bash
#
# harness/evaluate.sh — host-side evaluator for a Tier 2 bench run (R2-11).
#
# The machine cannot report its own pre-Linux failure, so the host evaluates the three
# monotone artifacts on the next run. The branches are R2-11's, in its order:
#
#   1. attempt.json + stages.log (2 lines) + result.json  -> PASS or FAIL, from result.json
#   2. attempt.json + stages.log (1 line), no result.json -> FAILED_USERSPACE
#   3. attempt.json, no stages.log                        -> FAILED_BOOT
#      ... and it REFUSES TO CLOSE until attempt.json carries a photograph.
#   4. no attempt.json                                    -> HARNESS_ERROR
#
# Where R2-11 is silent, this evaluator is deliberately strict rather than optimistic:
#
#   * stages.log with 2 lines but no result.json is FAILED_USERSPACE with
#     reason=smoke-test-did-not-complete (the machine reached userspace; the test did
#     not finish).
#   * stages.log with only a multi-user.target line means the early marker is missing.
#     That is an untrustworthy log (the monotone order is broken), so it is
#     HARNESS_ERROR, not FAILED_USERSPACE: the likely cause is the harness failing to
#     mount the results stick at sysinit, not a userspace fault.
#   * an empty or unparseable stages.log is HARNESS_ERROR, not FAILED_BOOT: nothing in
#     this harness creates an empty stages.log, so its emptiness is a harness fault.
#   * result.json whose booted KVER or image digest disagrees with attempt.json is
#     HARNESS_ERROR. A run that cannot prove *which* artifact was booted cannot
#     support a model claim.
#
# Exit codes: 0 PASS   1 FAIL   2 FAILED_USERSPACE   3 FAILED_BOOT   4 HARNESS_ERROR
#             20 UNCLOSED (FAILED_BOOT with no photograph: nothing written)
#             64 usage
#
# Exit 20 is not an outcome; it is a refusal. The run stays open until a photograph is
# attached:
#   evaluate.sh --run-dir DIR --photograph /path/to/photo.jpg

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/host-common.sh
source "$SCRIPT_DIR/lib/host-common.sh"

EXIT_PASS=0
EXIT_FAIL=1
EXIT_USERSPACE=2
EXIT_BOOT=3
EXIT_HARNESS=4
EXIT_UNCLOSED=20
EXIT_USAGE=64

RUN_DIR=""
RESULTS_ROOT=""
RUN_ID=""
PHOTOGRAPH_ARG=""
DRY_RUN=0
JSON_OUT=0

OUTCOME=""
STAGE_BOOT_ID=""
STAGE_BOOT_COUNT=0
REASON=""
DETAIL_JSON="{}"
VERDICT_WRITTEN=""
REACHED_STAGE=""
PHOTOGRAPH_RECORD=""
IMAGE_DIGEST=""

usage() {
  cat <<'EOF'
usage: evaluate.sh --run-dir DIR [--photograph PATH] [--dry-run] [--json]
       evaluate.sh --results-root DIR [--run-id ID] [--photograph PATH] ...

Evaluates one Tier 2 bench run against R2-11's four outcome branches.

  --run-dir DIR        the run directory holding attempt.json / stages.log / result.json
  --results-root DIR   results stick mountpoint; with no --run-id it reads DIR/CURRENT
  --run-id ID          run to evaluate under DIR/runs/
  --photograph PATH    attach the photograph and close a FAILED_BOOT run (copied into
                       the run directory, hashed, recorded in attempt.json)
  --dry-run            classify and print; write no verdict and change no artifact
  --json               print the verdict JSON instead of the human summary

Exit codes: 0 PASS, 1 FAIL, 2 FAILED_USERSPACE, 3 FAILED_BOOT, 4 HARNESS_ERROR,
            20 UNCLOSED (photograph required, nothing written), 64 usage.
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case $1 in
      --run-dir)      [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; RUN_DIR=$2; shift 2 ;;
      --results-root) [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; RESULTS_ROOT=$2; shift 2 ;;
      --run-id)       [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; RUN_ID=$2; shift 2 ;;
      --photograph)   [[ $# -ge 2 ]] || { usage >&2; exit "$EXIT_USAGE"; }; PHOTOGRAPH_ARG=$2; shift 2 ;;
      --dry-run)      DRY_RUN=1; shift ;;
      --json)         JSON_OUT=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) printf 'error: E_USAGE: unknown argument: %s\n' "$1" >&2; usage >&2; exit "$EXIT_USAGE" ;;
    esac
  done
}

resolve_run_dir() {
  if [[ -n $RUN_DIR ]]; then
    printf '%s\n' "$RUN_DIR"
    return 0
  fi
  [[ -n $RESULTS_ROOT ]] || return 1
  if [[ -n $RUN_ID ]]; then
    printf '%s\n' "$RESULTS_ROOT/runs/$RUN_ID"
    return 0
  fi
  if [[ -f $RESULTS_ROOT/CURRENT ]]; then
    local id
    id=$(head -n 1 "$RESULTS_ROOT/CURRENT" | tr -d '[:space:]')
    if [[ -n $id ]]; then
      printf '%s\n' "$RESULTS_ROOT/runs/$id"
      return 0
    fi
  fi
  # No pointer: newest run directory that holds an attempt.json.
  local newest
  newest=$(find "$RESULTS_ROOT/runs" -mindepth 2 -maxdepth 2 -name attempt.json -printf '%T@ %h\n' 2>/dev/null \
    | sort -n | tail -n 1 | cut -d' ' -f2- || true)
  [[ -n $newest ]] || return 1
  printf '%s\n' "$newest"
}

# jget <file> <jq-expr> [default] — a value or the default, never a failure.
jget() {
  local file=$1 expr=$2 def=${3:-} out
  [[ -f $file ]] || { printf '%s' "$def"; return 0; }
  out=$(jq -r "$expr" "$file" 2>/dev/null || true)
  if [[ -n $out && $out != null ]]; then printf '%s' "$out"; else printf '%s' "$def"; fi
}

# stages.log may hold more than one boot: a retried boot appends its own pair of lines
# (the 2026-10-21 run did exactly that — the first attempt was interrupted, the second
# produced result.json). Evaluation therefore reads the LAST boot's lines; the earlier
# boots stay in the log and are counted. Reading across boots is what made the original
# check see "multi-user.target before sysinit.target" and call a passing run a harness
# error.

stage_boot_count() {
  awk '/^stage=/ {
         for (i = 1; i <= NF; i++) {
           if ($i ~ /^boot=/) { if (!($i in seen)) { seen[$i] = 1; n++ } }
         }
       } END { print n + 0 }' "$1"
}

stage_last_boot() {
  awk '/^stage=/ {
         for (i = 1; i <= NF; i++) {
           if ($i ~ /^boot=/) { b = $i; sub(/^boot=/, "", b) }
         }
       } END { print b }' "$1"
}

stage_names() {
  # One name per valid stage line, in file order (duplicates preserved for the parser).
  # With a boot id, only that boot's lines are returned.
  awk -v boot="${2:-}" '
    /^stage=(sysinit\.target|multi-user\.target)([ \t]|$)/ {
      if (boot != "") {
        found = 0
        for (i = 1; i <= NF; i++) { if ($i == "boot=" boot) { found = 1 } }
        if (!found) { next }
      }
      sub(/^stage=/, ""); sub(/[ \t].*/, ""); print
    }' "$1"
}

stage_uptime() {
  local file=$1 want=$2 boot=${3:-}
  awk -v want="$want" -v boot="$boot" '
    $0 ~ "^stage=" want "([ \t]|$)" {
      if (boot != "") {
        found = 0
        for (i = 1; i <= NF; i++) { if ($i == "boot=" boot) { found = 1 } }
        if (!found) { next }
      }
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^uptime=/) { sub(/^uptime=/, "", $i); print $i; exit }
      }
    }' "$file"
}

stage_walltime() {
  local file=$1 want=$2 boot=${3:-}
  awk -v want="$want" -v boot="$boot" '
    $0 ~ "^stage=" want "([ \t]|$)" {
      if (boot != "") {
        found = 0
        for (i = 1; i <= NF; i++) { if ($i == "boot=" boot) { found = 1 } }
        if (!found) { next }
      }
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^time=/) { sub(/^time=/, "", $i); print $i; exit }
      }
    }' "$file"
}

exit_code_for() {
  case $1 in
    PASS) printf '%s' "$EXIT_PASS" ;;
    FAIL) printf '%s' "$EXIT_FAIL" ;;
    FAILED_USERSPACE) printf '%s' "$EXIT_USERSPACE" ;;
    FAILED_BOOT) printf '%s' "$EXIT_BOOT" ;;
    *) printf '%s' "$EXIT_HARNESS" ;;
  esac
}

# Close a FAILED_BOOT run: the photograph field must be filled in, either already or by
# --photograph. Exits 20 without writing anything when it is missing.
close_failed_boot() {
  local attempt=$1 existing resolved dest ext sha source_tmp
  existing=$(jget "$attempt" '.photograph // empty')

  if [[ -n $existing ]]; then
    resolved=$existing
    [[ $resolved == /* ]] || resolved="$RUN_DIR/$resolved"
    if [[ -s $resolved ]]; then
      PHOTOGRAPH_RECORD=$existing
      return 0
    fi
    hc_warn "attempt.json names a photograph that is missing or empty: $existing"
  fi

  if [[ -z $PHOTOGRAPH_ARG ]]; then
    cat >&2 <<EOF
error: E_NOT_CLOSED: FAILED_BOOT run $(basename -- "$RUN_DIR") is not closed.

There is no stages.log, which is the kernel/initramfs failure class. R2-11 requires a
photograph as part of that record, and no photograph is recorded in attempt.json.

Attach one and re-run; nothing has been written and the run stays open:
  $SCRIPT_DIR/evaluate.sh --run-dir $RUN_DIR --photograph /path/to/photo.jpg

The photograph is the only capture path for this class: a T2 Mac has no serial console.
EOF
    exit "$EXIT_UNCLOSED"
  fi

  [[ -f $PHOTOGRAPH_ARG ]] || hc_die "$EXIT_UNCLOSED" E_PHOTOGRAPH_MISSING \
    "--photograph $PHOTOGRAPH_ARG is not a regular file; the run stays open"
  [[ -s $PHOTOGRAPH_ARG ]] || hc_die "$EXIT_UNCLOSED" E_PHOTOGRAPH_EMPTY \
    "--photograph $PHOTOGRAPH_ARG is empty; the run stays open"

  ext=${PHOTOGRAPH_ARG##*.}
  [[ $ext =~ ^[A-Za-z0-9]{1,5}$ ]] || ext=bin
  dest="$RUN_DIR/photograph.$ext"

  if (( DRY_RUN == 1 )); then
    hc_warn "dry-run: would copy $PHOTOGRAPH_ARG -> $dest and close the run"
    PHOTOGRAPH_RECORD="photograph.$ext"
    return 0
  fi

  if [[ $(hc_device_real "$PHOTOGRAPH_ARG") != $(hc_device_real "$dest") ]]; then
    cp -- "$PHOTOGRAPH_ARG" "$dest"
  fi
  hc_sync_file "$dest"
  sha=$(sha256sum -- "$dest" | awk '{ print $1 }')
  source_tmp=$(hc_device_real "$PHOTOGRAPH_ARG")

  update_attempt_photograph "$attempt" "photograph.$ext" "$source_tmp" "$sha"
  PHOTOGRAPH_RECORD="photograph.$ext"
}

update_attempt_photograph() {
  local attempt=$1 name=$2 source=$3 sha=$4 tmp
  tmp=$(mktemp "$RUN_DIR/.attempt.XXXXXX")
  jq --arg p "$name" --arg s "$source" --arg h "$sha" --arg at "$(hc_now)" \
    '.photograph = $p
     | .photograph_source = $s
     | .photograph_sha256 = $h
     | .closed_at = $at' \
    "$attempt" > "$tmp"
  hc_sync_file "$tmp"
  mv -- "$tmp" "$attempt"
  hc_sync_file "$RUN_DIR"
}

write_verdict() {
  local code verdict_path tmp attempt stages result
  attempt="$RUN_DIR/attempt.json"
  stages="$RUN_DIR/stages.log"
  result="$RUN_DIR/result.json"
  code=$(exit_code_for "$OUTCOME")

  local image_digest image_ref kver boot_device boot_model sb_state
  local stages_exists=false stages_lines=0 result_exists=false result_status=""
  local stage_boot="" stage_boots=0
  local failed_assertions="[]" names_json="[]" uptimes_json='{}'
  local -a names=()
  local sysinit_s multi_s
  image_digest=$(jget "$attempt" '.image.digest // empty')
  image_ref=$(jget "$attempt" '.image.ref // empty')
  kver=$(jget "$attempt" '.image.kver // empty')
  boot_device=$(jget "$attempt" '.boot_target.device // empty')
  boot_model=$(jget "$attempt" '.boot_target.model // empty')
  sb_state=$(jget "$attempt" '.secure_boot.state // empty')

  if [[ -f $stages ]]; then
    stages_exists=true
    stages_lines=$(wc -l < "$stages" | tr -d '[:space:]')
    stage_boot=$(stage_last_boot "$stages")
    stage_boots=$(stage_boot_count "$stages")
    mapfile -t names < <(stage_names "$stages" "$stage_boot")
    names_json=$(hc_json_array "${names[@]}")
    sysinit_s=$(stage_uptime "$stages" sysinit.target "$stage_boot" || true)
    multi_s=$(stage_uptime "$stages" multi-user.target "$stage_boot" || true)
    [[ -n $sysinit_s ]] || sysinit_s=null
    [[ -n $multi_s ]] || multi_s=null
    uptimes_json=$(jq -n --argjson sysinit "$sysinit_s" --argjson multi_user "$multi_s" \
      '{ sysinit_s: $sysinit, multi_user_s: $multi_user }')
  fi
  if [[ -f $result ]]; then
    result_exists=true
    result_status=$(jget "$result" '.status // empty')
    failed_assertions=$(jq -c '.failed_assertions // []' "$result" 2>/dev/null || printf '[]')
  fi

  verdict_path="$RUN_DIR/verdict.json"
  if (( DRY_RUN == 0 )); then
    tmp=$(mktemp "$RUN_DIR/.verdict.XXXXXX")
    jq -n \
      --argjson schema 1 \
      --arg kind "verdict" \
      --arg run_id "$(basename -- "$RUN_DIR")" \
      --arg outcome "$OUTCOME" \
      --argjson exit_code "$code" \
      --arg reason "$REASON" \
      --arg evaluated_at "$(hc_now)" \
      --arg run_dir "$RUN_DIR" \
      --arg image_ref "$image_ref" \
      --arg image_digest "$image_digest" \
      --arg kver "$kver" \
      --arg boot_device "$boot_device" \
      --arg boot_model "$boot_model" \
      --arg sb_state "$sb_state" \
      --argjson stages_exists "$stages_exists" \
      --argjson stages_lines "$stages_lines" \
      --argjson stage_names "$names_json" \
      --argjson stage_uptimes "$uptimes_json" \
      --arg stage_boot "$stage_boot" \
      --argjson stage_boots "$stage_boots" \
      --argjson result_exists "$result_exists" \
      --arg result_status "$result_status" \
      --argjson failed_assertions "$failed_assertions" \
      --arg photograph "$PHOTOGRAPH_RECORD" \
      --arg reached_stage "$REACHED_STAGE" \
      --argjson detail "$DETAIL_JSON" \
      --arg evaluator_host "$(hostname)" \
      --arg evaluator_user "$(id -un)" \
      --argjson dry_run "$DRY_RUN" \
      '{
         schema: $schema,
         kind: $kind,
         run_id: $run_id,
         outcome: $outcome,
         exit_code: $exit_code,
         reason: $reason,
         evaluated_at: $evaluated_at,
         run_dir: $run_dir,
         evaluator: { version: 1, host: $evaluator_host, user: $evaluator_user, dry_run: $dry_run },
         image: { ref: $image_ref, digest: $image_digest, kver: $kver },
         boot_target: { device: $boot_device, model: $boot_model },
         secure_boot: { state: $sb_state },
         stages: {
           exists: $stages_exists,
           line_count: $stages_lines,
           names: $stage_names,
           boots: $stage_boots,
           boot_id: (if $stage_boot == "" then null else $stage_boot end),
           reached_stage: (if $reached_stage == "" then null else $reached_stage end),
           uptimes_s: $stage_uptimes
         },
         result: {
           exists: $result_exists,
           status: (if $result_status == "" then null else $result_status end),
           failed_assertions: $failed_assertions
         },
         photograph: (if $photograph == "" then null else $photograph end),
         detail: $detail
       }' > "$tmp"
    hc_sync_file "$tmp"
    mv -- "$tmp" "$verdict_path"
    hc_sync_file "$RUN_DIR"
    VERDICT_WRITTEN=$verdict_path
  fi

  if (( JSON_OUT == 1 )); then
    if [[ -n $VERDICT_WRITTEN ]]; then
      cat "$VERDICT_WRITTEN"
    else
      printf '%s\n' "$(jq -nc --arg run_id "$(basename -- "$RUN_DIR")" --arg outcome "$OUTCOME" \
        --arg reason "$REASON" --argjson exit_code "$code" \
        '{run_id:$run_id, outcome:$outcome, reason:$reason, exit_code:$exit_code, dry_run:true}')"
    fi
  else
    print_summary "$code"
  fi
  exit "$code"
}

print_summary() {
  local code=$1
  printf 'run:       %s\n' "$(basename -- "$RUN_DIR")"
  printf 'run dir:   %s\n' "$RUN_DIR"
  local image_line kver_line
  image_line=${IMAGE_DIGEST:-$(jget "$RUN_DIR/attempt.json" '.image.digest // empty')}
  kver_line=$(jget "$RUN_DIR/attempt.json" '.image.kver // empty')
  [[ -n $image_line ]] || image_line="(none recorded)"
  [[ -n $kver_line ]] || kver_line="(none recorded)"
  printf 'image:     %s\n' "$image_line"
  printf 'kver:      %s\n' "$kver_line"
  printf 'outcome:   %s\n' "$OUTCOME"
  printf 'reason:    %s\n' "$REASON"
  case $OUTCOME in
    PASS)
      printf 'detail:    every smoke assertion passed; KVER and digest match attempt.json\n'
      ;;
    FAIL)
      printf 'detail:    failed assertions: %s\n' \
        "$(jget "$RUN_DIR/result.json" '.failed_assertions | join(", ")' 'none recorded')"
      ;;
    FAILED_USERSPACE)
      printf 'detail:    reached %s; result.json is absent — userspace died or hung after that stage\n' \
        "${REACHED_STAGE:-an unrecorded stage}"
      ;;
    FAILED_BOOT)
      printf 'detail:    no stages.log — the kernel or initramfs never reached sysinit\n'
      printf 'photograph: %s\n' "${PHOTOGRAPH_RECORD:-none}"
      ;;
    HARNESS_ERROR)
      printf 'detail:    %s\n' "$(printf '%s' "$DETAIL_JSON" | jq -r '.hint // "harness fault; see verdict"')"
      ;;
  esac
  if [[ -n $VERDICT_WRITTEN ]]; then
    printf 'verdict:   %s\n' "$VERDICT_WRITTEN"
  elif (( DRY_RUN == 1 )); then
    printf 'verdict:   not written (dry-run)\n'
  fi
  printf 'exit:      %s\n' "$code"
}

finish() {
  write_verdict
}

main() {
  parse_args "$@"

  local resolved
  if ! resolved=$(resolve_run_dir); then
    OUTCOME=HARNESS_ERROR
    REASON="no-run"
    DETAIL_JSON='{"hint":"pass --run-dir, or --results-root with CURRENT / --run-id"}'
    printf 'error: E_NO_RUN: no run directory found (no --run-dir, no CURRENT, no runs/*/attempt.json)\n' >&2
    if (( JSON_OUT == 1 )); then
      jq -nc '{outcome:"HARNESS_ERROR", reason:"no-run", exit_code:4}'
    fi
    exit "$EXIT_HARNESS"
  fi
  RUN_DIR=$resolved

  if [[ ! -d $RUN_DIR ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="no-run-directory"
    DETAIL_JSON=$(jq -nc --arg d "$RUN_DIR" '{hint: ("run directory does not exist: " + $d)}')
    printf 'error: E_NO_RUN_DIR: %s does not exist\n' "$RUN_DIR" >&2
    printf 'outcome:   HARNESS_ERROR\nreason:    %s\n' "$REASON" >&2
    exit "$EXIT_HARNESS"
  fi

  local attempt="$RUN_DIR/attempt.json"
  local stages="$RUN_DIR/stages.log"
  local result="$RUN_DIR/result.json"

  # Branch 4: no attempt.json.
  if [[ ! -f $attempt ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="no-attempt.json"
    DETAIL_JSON='{"hint":"the host never recorded the attempt; if this directory is the right one, install-to-disk/attempt did not run"}'
    finish
  fi
  if ! jq -e '.kind == "attempt"' "$attempt" >/dev/null 2>&1; then
    OUTCOME=HARNESS_ERROR
    REASON="attempt-unreadable"
    DETAIL_JSON='{"hint":"attempt.json exists but is not a readable attempt record; treat this run as unusable"}'
    finish
  fi

  IMAGE_DIGEST=$(jget "$attempt" '.image.digest // empty')

  # Branch 3: no stages.log -> FAILED_BOOT, and it will not close without a photograph.
  if [[ ! -e $stages ]]; then
    close_failed_boot "$attempt"
    OUTCOME=FAILED_BOOT
    REASON="no-stages.log"
    DETAIL_JSON=$(jq -nc --argjson t "$(jget "$attempt" '.timeout_s // empty' 0)" \
      '{hint:"kernel or initramfs never reached sysinit.target; the timeout is recorded in attempt.json", timeout_s:$t}')
    finish
  fi

  # Parse the stage log. A retried boot appends a second pair of lines; the run's artefact
  # is the last boot, which is the one result.json belongs to.
  local -a names=()
  STAGE_BOOT_COUNT=$(stage_boot_count "$stages")
  STAGE_BOOT_ID=$(stage_last_boot "$stages")
  mapfile -t names < <(stage_names "$stages" "$STAGE_BOOT_ID")
  if (( ${#names[@]} == 0 )); then
    if [[ ! -s $stages ]]; then
      OUTCOME=HARNESS_ERROR
      REASON="stages-empty"
      DETAIL_JSON='{"hint":"stages.log exists but is empty; nothing in this harness creates an empty log, so this is a harness fault"}'
    else
      OUTCOME=HARNESS_ERROR
      REASON="stages-unparseable"
      DETAIL_JSON=$(jq -nc --arg tail "$(tail -n 3 "$stages" 2>/dev/null || true)" \
        '{hint:"stages.log holds no stage= line; the artifact cannot localise the failure", last_lines:$tail}')
    fi
    finish
  fi

  # Monotone order: sysinit first, then multi-user.
  if [[ ${names[0]} != sysinit.target ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="stage-order-inverted"
    DETAIL_JSON=$(jq -nc --arg first "${names[0]}" --argjson n "${#names[@]}" \
      '{hint:"stages.log starts with a multi-user.target line and has no sysinit line; the early marker is missing (the results stick was probably not mounted yet), so the log cannot localise the failure", first_stage:$first, lines:$n}')
    finish
  fi
  local i prev=""
  for i in "${names[@]}"; do
    if [[ $i == sysinit.target && $prev == multi-user.target ]]; then
      OUTCOME=HARNESS_ERROR
      REASON="stage-order-inverted"
      DETAIL_JSON='{"hint":"stages.log records multi-user.target before sysinit.target"}'
      finish
    fi
    prev=$i
  done

  local i has_sysinit=0 has_multi=0
  for i in "${names[@]}"; do
    case $i in
      sysinit.target) has_sysinit=1 ;;
      multi-user.target) has_multi=1 ;;
    esac
  done

  if (( has_sysinit == 1 && has_multi == 0 )); then
    REACHED_STAGE=sysinit.target
    if [[ -f $result ]]; then
      OUTCOME=HARNESS_ERROR
      REASON="result-without-userspace-stage"
      DETAIL_JSON='{"hint":"result.json exists but stages.log stops at sysinit.target; the artifacts contradict each other, so neither is trustworthy"}'
      finish
    fi
    OUTCOME=FAILED_USERSPACE
    REASON="stages-1-line"
    DETAIL_JSON='{"hint":"kernel and initramfs completed (sysinit reached); no result.json and no multi-user line, so userspace died or hung"}'
    finish
  fi

  REACHED_STAGE=multi-user.target

  # Two stages but no result: userspace was reached, the test did not finish.
  if [[ ! -f $result ]]; then
    OUTCOME=FAILED_USERSPACE
    REASON="smoke-test-did-not-complete"
    DETAIL_JSON='{"hint":"multi-user.target was reached but result.json was never written; the smoke test hung, crashed, or could not write to the results stick"}'
    finish
  fi

  if ! jq -e '.kind == "result"' "$result" >/dev/null 2>&1; then
    OUTCOME=HARNESS_ERROR
    REASON="result-unreadable"
    DETAIL_JSON='{"hint":"result.json exists but is not a readable result record"}'
    finish
  fi

  local status r_kver r_digest a_kver a_digest
  status=$(jget "$result" '.status // empty')
  case $status in
    pass|fail) : ;;
    *)
      OUTCOME=HARNESS_ERROR
      REASON="result-status-invalid"
      DETAIL_JSON=$(jq -nc --arg s "$status" '{hint:"result.json status must be pass or fail", status:$s}')
      finish
      ;;
  esac

  # Integrity: the result must prove which artifact was booted.
  a_kver=$(jget "$attempt" '.image.kver // empty')
  a_digest=$(jget "$attempt" '.image.digest // empty')
  r_kver=$(jget "$result" '.booted_kver // empty')
  r_digest=$(jget "$result" '.image_digest // empty')
  if [[ -z $r_digest ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="digest-unrecorded"
    DETAIL_JSON='{"hint":"result.json does not record the booted image digest, so the run is not digest-pinned evidence"}'
    finish
  fi
  if [[ $r_digest != "$a_digest" ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="digest-mismatch"
    DETAIL_JSON=$(jq -nc --arg a "$a_digest" --arg r "$r_digest" \
      '{hint:"the booted image digest does not match the attempt; this run is not evidence about the recorded image", attempt_digest:$a, booted_digest:$r}')
    finish
  fi
  if [[ -z $r_kver ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="kver-unrecorded"
    DETAIL_JSON='{"hint":"result.json does not record the booted kernel, so kernel/module lockstep cannot be checked"}'
    finish
  fi
  if [[ $r_kver != "$a_kver" ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="kver-mismatch"
    DETAIL_JSON=$(jq -nc --arg a "$a_kver" --arg r "$r_kver" \
      '{hint:"the booted kernel is not the kernel the attempt recorded; modules built for the recorded KVER would not load", attempt_kver:$a, booted_kver:$r}')
    finish
  fi

  # The four hard assertions must be present, and the status must agree with them.
  if ! jq -e '(.assertions | type == "object")
              and (.assertions.modules.ok | type == "boolean")
              and (.assertions.firmware.ok | type == "boolean")
              and (.assertions.wifi.ok | type == "boolean")
              and (.assertions.systemd_failed.ok | type == "boolean")' "$result" >/dev/null 2>&1; then
    OUTCOME=HARNESS_ERROR
    REASON="result-assertions-incomplete"
    DETAIL_JSON='{"hint":"result.json does not carry all four named assertions (modules, firmware, wifi, systemd_failed)"}'
    finish
  fi

  local all_ok
  all_ok=$(jq -r 'try ([.assertions[].ok] | all) catch "error"' "$result" 2>/dev/null || printf 'error')
  if [[ $all_ok != true && $all_ok != false ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="result-assertions-unreadable"
    DETAIL_JSON='{"hint":"cannot read the assertion booleans out of result.json"}'
    finish
  fi
  if [[ $status == pass && $all_ok != true ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="pass-with-failed-assertion"
    DETAIL_JSON='{"hint":"result.json says pass but at least one named assertion is false"}'
    finish
  fi
  if [[ $status == fail && $all_ok == true ]]; then
    OUTCOME=HARNESS_ERROR
    REASON="fail-without-failed-assertion"
    DETAIL_JSON='{"hint":"result.json says fail but every named assertion is true; the verdict is not self-consistent"}'
    finish
  fi

  if [[ $status == pass ]]; then
    OUTCOME=PASS
    REASON="all-assertions-passed"
  else
    OUTCOME=FAIL
    REASON="smoke-assertions-failed"
  fi
  finish
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
