#!/usr/bin/env bash
# /usr/libexec/bluefin-t2-hil/lib.sh — shared by stage-log and smoke-test.
#
# SOURCED, never executed. This file runs on the INSTALLED bench image, not on the
# bench host: it must not source harness/lib/host-common.sh, and must not assume jq,
# skopeo or python3. It uses bash, coreutils, util-linux and (where available) nmcli,
# dmesg and bootc, all of which the image carries.
#
# Install path (bench image only, never the release image):
#   harness/rootfs/usr/libexec/bluefin-t2-hil/{lib.sh,stage-log,smoke-test}
#
# Results layout, on the dedicated FAT32 stick labelled K2B-HIL:
#   /var/mnt/hil/CURRENT                 run id of the attempt being booted (host-written)
#   /var/mnt/hil/runs/<run-id>/attempt.json    host, before power-on
#   /var/mnt/hil/runs/<run-id>/stages.log      this side, at sysinit and multi-user
#   /var/mnt/hil/runs/<run-id>/result.json     this side, smoke test
#
# The booted side never writes attempt.json. It only appends stage lines and writes its
# own result.

HIL_VERSION="1"
HIL_RESULTS_LABEL=${HIL_RESULTS_LABEL:-K2B-HIL}
HIL_RESULTS_ROOT=${HIL_RESULTS_ROOT:-/var/mnt/hil}
HIL_MOUNT_WAIT=${HIL_MOUNT_WAIT:-30}
HIL_MODELS_DIR=${HIL_MODELS_DIR:-/usr/share/bluefin-t2/models.d}
HIL_STAGE_NAMES="sysinit.target multi-user.target"

hil_log() { printf 'bluefin-t2-hil: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Minimal JSON emission (no jq on this side)
# ---------------------------------------------------------------------------

hil_json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

hil_json_string() { printf '"%s"' "$(hil_json_escape "${1-}")"; }

hil_json_string_or_null() {
  if [[ -n ${1-} ]]; then hil_json_string "$1"; else printf 'null'; fi
}

hil_json_array() {
  local first=1 v
  printf '['
  for v in "$@"; do
    (( first == 1 )) || printf ','
    first=0
    hil_json_string "$v"
  done
  printf ']'
}

hil_json_number_or_null() {
  if [[ ${1-} =~ ^[0-9]+$ ]]; then printf '%s' "$1"; else printf 'null'; fi
}

# ---------------------------------------------------------------------------
# Clock, boot identity, durable writes
# ---------------------------------------------------------------------------

hil_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
hil_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf 'unknown'; }

hil_uptime_s() {
  local up="."
  read -r up _ < /proc/uptime 2>/dev/null || true
  printf '%s' "${up%%.*}"
}

# sync -f is fsync-of-file on coreutils >= 8.24; fall back to a global sync.
hil_sync_file() {
  local f=$1
  sync -f "$f" 2>/dev/null || sync 2>/dev/null || true
}

# hil_stage_line <stage> <walltime> <uptime_s> <boot_id> — one appended, parseable line.
hil_stage_line() {
  printf 'stage=%s time=%s uptime=%s boot=%s\n' "$1" "$2" "$3" "$4"
}

# ---------------------------------------------------------------------------
# Results device
# ---------------------------------------------------------------------------

# Find and mount the results stick. Safe to call more than once.
hil_ensure_results_mount() {
  local label="/dev/disk/by-label/$HIL_RESULTS_LABEL"
  local root=$HIL_RESULTS_ROOT i
  if mountpoint -q "$root" 2>/dev/null; then
    return 0
  fi
  # Test-only seam for harness/selftest.sh, which cannot mount anything on the host.
  # Production never sets this; the units do not reference it.
  if [[ ${HIL_SKIP_MOUNT:-0} == 1 && -d $root ]]; then
    hil_log "HIL_SKIP_MOUNT=1: using $root without mounting (test mode)"
    return 0
  fi
  mkdir -p "$root" 2>/dev/null || true
  for (( i = 0; i < HIL_MOUNT_WAIT; i++ )); do
    [[ -e $label ]] && break
    sleep 1
  done
  if [[ ! -e $label ]]; then
    hil_log "results device $label did not appear within ${HIL_MOUNT_WAIT}s"
    return 1
  fi
  # vfat options first (the designed medium), then a plain mount for anything else.
  if ! mount -o rw,umask=0022,flush "$label" "$root" 2>/dev/null; then
    if ! mount -o rw "$label" "$root" 2>/dev/null; then
      hil_log "could not mount $label at $root"
      return 1
    fi
  fi
  mountpoint -q "$root" 2>/dev/null || return 1
  hil_log "mounted $label at $root"
  return 0
}

# The run being booted: CURRENT first, then the newest run with an attempt.json.
hil_run_dir() {
  local root=$HIL_RESULTS_ROOT id="" newest=""
  if [[ -r $root/CURRENT ]]; then
    id=$(head -n 1 "$root/CURRENT" 2>/dev/null | tr -d '[:space:]')
    if [[ -n $id && -d $root/runs/$id ]]; then
      printf '%s\n' "$root/runs/$id"
      return 0
    fi
    hil_log "CURRENT names '${id:-<empty>}' but $root/runs/$id is not a directory"
  fi
  newest=$(ls -1dt "$root"/runs/*/attempt.json 2>/dev/null | head -n 1 || true)
  if [[ -n $newest ]]; then
    dirname -- "$newest"
    return 0
  fi
  hil_log "no run directory on $root (no CURRENT and no runs/*/attempt.json)"
  return 1
}

# Append one stage line under a lock, then fsync it. Never creates a torn line.
hil_append_stage() {
  local stage=$1 run_dir log line
  run_dir=$(hil_run_dir) || return 1
  log="$run_dir/stages.log"
  line=$(hil_stage_line "$stage" "$(hil_now)" "$(hil_uptime_s)" "$(hil_boot_id)")

  if command -v flock >/dev/null 2>&1; then
    {
      flock 9
      printf '%s\n' "$line" >&9
      hil_sync_file "$log"
    } 9>>"$log"
  else
    printf '%s\n' "$line" >> "$log"
    hil_sync_file "$log"
  fi
  hil_log "stage $stage recorded in $log"
  return 0
}

# ---------------------------------------------------------------------------
# models.d
# ---------------------------------------------------------------------------

# The schema this harness expects (one TOML per model, three categories):
#
#   expected_loaded  = ["t2bce_dma", ...]      # loads and binds (or is a no-device load)
#   expected_unbound = ["hid_t2magicmouse"]    # loads, no device binds it
#   expected_absent  = ["t2gmux"]              # present in the image, correctly not loaded
#
# A literal "unmeasured" inside a list is skipped and recorded, never asserted: §4 uses
# it for models whose exceptions have not been measured yet.
#
# Exit codes of the category readers: 0 ok, 2 file unreadable, 4 key absent,
# 5 value is not a list of strings.

hil_models_category_python() {
  python3 - "$1" "$2" <<'PY'
import sys
try:
    import tomllib
except Exception:
    sys.exit(3)
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, "rb") as fh:
        doc = tomllib.load(fh)
except Exception as exc:  # noqa: BLE001 - any read is "unreadable" here
    print(f"unreadable TOML: {exc}", file=sys.stderr)
    sys.exit(2)
if key not in doc:
    sys.exit(4)
val = doc[key]
if isinstance(val, str):
    val = [val]
if not isinstance(val, list) or not all(isinstance(v, str) for v in val):
    sys.exit(5)
for item in val:
    print(item)
PY
}

# Fallback parser: inline arrays, single line, no TOML library. Good enough for the
# schema above, and it is also what runs when python3 has no tomllib.
hil_models_category_awk() {
  awk -v key="$2" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line = $0
      sub(/^[^=]*=[[:space:]]*\[/, "", line)
      # An array may be written across several lines; accumulate until the closing
      # bracket, or EOF (a malformed value is then read as far as it goes).
      if (line !~ /\]/) {
        while ((getline more) > 0) {
          line = line " " more
          if (line ~ /\]/) break
        }
      }
      sub(/\].*/, "", line)
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/[[:space:]"]/, "", parts[i])
        if (parts[i] != "") print parts[i]
      }
      found = 1
      exit
    }
    END { if (!found) exit 4 }
  ' "$1"
}

hil_models_category() {
  local file=${1-} key=${2-} out="" rc=0
  [[ -n $file && -n $key ]] || return 2
  [[ -f $file ]] || return 2
  if command -v python3 >/dev/null 2>&1; then
    if out=$(hil_models_category_python "$file" "$key"); then
      printf '%s\n' "$out" | sed '/^$/d'
      return 0
    fi
    rc=$?
    case $rc in
      2|4|5) return "$rc" ;;
      *) : ;; # 3 = no tomllib, or python3 failed: fall back to awk
    esac
  fi
  hil_models_category_awk "$file" "$key"
}
