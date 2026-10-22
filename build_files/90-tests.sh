#!/usr/bin/bash
# bluefin-t2 Tier 0 gates for the bench slice. Runs inside the build, after the
# initramfs. Every assertion here is a named set, never a count: a count passes when
# the set is wrong and the arithmetic matches.
#
# A failure here is the result, not an obstacle. Do not delete an assertion to make a
# build green; the assertion is the property.

set -euo pipefail

KVER="${1:?usage: 90-tests.sh <KVER>}"
MODDIR="/lib/modules/${KVER}"

fail() { echo "GATE FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

# The 18 objects, exactly. T2 of the design, §14.
EXPECTED_OBJECTS=(
    t2bce_dma t2bce_core t2bce_vhci t2bce_audio t2bce_ave
    t2hid t2touchbar_kbd t2touchbar_bl
    hid_t2magicmouse
    t2bdrm t2smc t2sbs t2mfi_fastcharge t2gmux t2thunderbolt t2smp
    t2_precision_trackpad t2_trackpad_actuator
)
# The early-boot set: the BCE stack plus HID plus SMC/SBS, forced into the initramfs.
EARLY_OBJECTS=( t2bce_dma t2bce_core t2bce_vhci t2hid t2smc t2sbs )

echo "== 1. kernel identity =="
installed_kernels="$(ls -1 /lib/modules)"
[[ "$installed_kernels" == "$KVER" ]] \
    || fail "expected exactly one kernel tree '$KVER', found: $installed_kernels"
pass "exactly one kernel tree: $KVER"

echo "== 2. the 18 objects, by name =="
# Collect the path of each of OUR objects. This is deliberately per-object rather than a
# "what is in extra/" comparison, because extra/ is not ours alone: the Bluefin base
# already ships its own akmods there (zfs, spl, v4l2loopback). Asserting that extra/
# equals our 18 fails for the right reason (the base is a derivative, not a blank disk)
# and would tempt someone to delete the assertion instead of fixing it.
our_kos=()
for m in "${EXPECTED_OBJECTS[@]}"; do
    mapfile -t hits < <(find "$MODDIR" -name "${m}.ko*")
    [[ "${#hits[@]}" -eq 1 ]] \
        || fail "expected exactly one ${m}.ko*, found ${#hits[@]}: ${hits[*]:-<none>}"
    our_kos+=("${hits[0]}")
done

# Every object that names itself one of ours must be in the named set. A stale, renamed
# or typo'd t2 module is exactly what this catches; Bluefin's unrelated kmods are allowed.
found_in_extra="$(find "$MODDIR"/extra -name '*.ko*' -printf '%f\n' 2>/dev/null \
    | sed -E 's/\.ko(\.xz|\.gz|\.zst)?$//' | sort -u)"
unexpected="$(comm -13 \
    <(printf '%s\n' "${EXPECTED_OBJECTS[@]}" | sort -u) \
    <(printf '%s\n' "$found_in_extra") \
    | grep -E '^(hid_)?t2' || true)"
[[ -z "$unexpected" ]] \
    || fail "unexpected t2 object(s) in extra/: $(echo "$unexpected" | tr '\n' ' ')"
pass "18/18 objects present; no unexpected t2 object (base kmods ignored)"

echo "== 3. vermagic for every object of ours =="
for ko in "${our_kos[@]}"; do
    v="$(modinfo -F vermagic "$ko" | awk '{print $1}')"
    [[ "$v" == "$KVER" ]] || fail "vermagic '$v' != '$KVER' for $ko"
done
pass "all 18 carry vermagic $KVER"

echo "== 4. every object of ours is signed =="
for ko in "${our_kos[@]}"; do
    signer="$(modinfo -F signer "$ko" || true)"
    sig_id="$(modinfo -F sig_id "$ko" || true)"
    [[ -n "$signer" ]] || fail "unsigned module: $ko"
    [[ "$sig_id" == "PKCS#7" ]] || fail "unexpected sig_id '$sig_id' for $ko"
done
pass "all 18 signed, PKCS#7"

echo "== 5. depmod resolved every object =="
# Path-tolerant: a kmod RPM may install into extra/<name>/ rather than extra/ directly.
for m in "${EXPECTED_OBJECTS[@]}"; do
    grep -qE "(^|/)${m}\.ko:" "$MODDIR/modules.dep" \
        || fail "${m} missing from modules.dep"
done
# depmod prints nothing on success; an unresolved-symbol complaint is a failure. Capture
# both the status and the output, because "depmod died" and "depmod complained" differ.
depmod_out="$(depmod -a "$KVER" 2>&1)" || { echo "$depmod_out" >&2; fail "depmod -a $KVER failed"; }
if grep -qi 'unresolved' <<<"$depmod_out"; then
    echo "$depmod_out" >&2
    fail "depmod reports unresolved symbols"
fi
pass "all 18 objects in modules.dep; depmod clean"

echo "== 6. the initramfs guarantee — by name, via lsinitrd =="
INITRD="$MODDIR/initramfs.img"
[[ -s "$INITRD" ]] || fail "initramfs missing at $INITRD"
# Grep a FILE, never `lsinitrd ... | grep -q`. Under `set -o pipefail`, grep exits on the
# first match, the writer takes SIGPIPE, and the pipeline reports 141 — so a *successful*
# match looks like a failure. That false negative cost one build here; a file cannot
# reproduce it.
initrd_list="$(mktemp)"
lsinitrd "$INITRD" > "$initrd_list" 2>/dev/null || true
if [[ ! -s "$initrd_list" ]]; then
    rm -f "$initrd_list"
    fail "lsinitrd produced no listing for $INITRD"
fi
for m in "${EARLY_OBJECTS[@]}"; do
    if ! grep -qE "(^|/)${m}\.ko" "$initrd_list"; then
        rm -f "$initrd_list"
        fail "initramfs is missing ${m}.ko — dracut only warns, so this assertion is the proof"
    fi
done
rm -f "$initrd_list"
pass "initramfs carries all six early-boot objects"

echo "== 7. the kargs set, as the named 13 =="
KARGS="/usr/lib/bootc/kargs.d/00-t2.toml"
[[ -f "$KARGS" ]] || fail "missing $KARGS"
expected_kargs='kargs = [
  "amdgpu.aspm=1",
  "i915.enable_guc=2",
  "intel_iommu=on",
  "iommu=pt",
  "pm_async=off",
  "brcmfmac.p2pon=0",
  "pcie_aspm=force",
  "pcie_aspm.policy=powersave",
  "pcie_ports=compat",
  "mem_sleep_default=deep",
  "initcall_blacklist=cmos_init,magicmouse_driver_init",
  "module_blacklist=acpi_tad,applesmc,macsmc,hid_apple,hid_appletb_bl,hid_appletb_kbd,hid_magicmouse,appletbdrm,apple_bce,apple_mfi_fastcharge,apple_gmux,sbs",
  "firmware_class.path=/var/lib/firmware",
]'
# Compare the array itself, not the file: the file carries comments explaining each
# argument, and comment/whitespace churn must not fail a value assertion. The array is
# the content; the comments are documentation.
actual_kargs="$(sed -n '/^kargs = \[/,/^\]/p' "$KARGS")"
[[ -n "$actual_kargs" ]] || fail "no 'kargs = [' array found in $KARGS"
if ! diff -u <(printf '%s\n' "$expected_kargs") <(printf '%s\n' "$actual_kargs"); then
    fail "kargs array does not match the named 13 (diff above)"
fi
pass "13 kargs, exact and diffable"

echo "== 8. no build-only residue from OUR steps =="
# Careful: the base Bluefin image legitimately ships a development toolchain — gcc,
# gcc-c++, make, checkpolicy, and kernel-headers (which owns
# /usr/include/linux/version.h). Asserting THOSE absent fails on a correct image, which
# is how this assertion was first written. What must be absent is what would let the
# image build or carry a module for the wrong kernel: kernel-devel, the /usr/src tree,
# and our own staging directory.
if [[ -e /usr/src/kernels ]]; then
    fail "kernel-devel tree present at /usr/src/kernels — it must not be in the image"
fi
if rpm -q kernel-devel >/dev/null 2>&1; then
    fail "kernel-devel is installed in the image"
fi
if [[ -e /tmp/t2-kmods ]]; then
    fail "kmod staging directory left behind at /tmp/t2-kmods"
fi
# The builder stage installs cargo/rust/GTK devel; none of it may cross into the image.
# These are absent from the Bluefin base, so their presence would mean the final stage
# accidentally inherited the build tree rather than only /out.
for p in cargo rust gtk4-devel libadwaita-devel libplist-devel libinput-devel; do
    if rpm -q "$p" >/dev/null 2>&1; then
        fail "builder-only package leaked into the image: $p"
    fi
done
pass "no kernel-devel, no /usr/src tree, no kmod staging, no builder-only packages"

echo "== 9. the forced-driver list matches the early set =="
FORCE_CONF="/usr/lib/dracut/dracut.conf.d/90-t2-input.conf"
[[ -f "$FORCE_CONF" ]] || fail "missing $FORCE_CONF"
declared="$(grep -oE 'force_drivers\+="[^"]+"' "$FORCE_CONF" | sed -E 's/.*="(.*)"/\1/' | tr -s ' ' '\n' | grep -v '^$' | sort)"
wanted="$(printf '%s\n' "${EARLY_OBJECTS[@]}" | sort)"
[[ "$declared" == "$wanted" ]] || {
    echo "--- declared ---" >&2; echo "$declared" >&2
    echo "--- wanted ---" >&2;   echo "$wanted" >&2
    fail "force_drivers list does not equal the six early-boot objects"
}
pass "force_drivers equals the six"


echo "== 10. the Tier 2 harness layer (bench slice only) =="
if [[ "${RELEASE:-0}" == "1" ]]; then
    # The release image must not carry the harness: no stage loggers, no HIL units, no
    # wants links. The harness is a measurement surface, not product surface.
    for f in /usr/libexec/bluefin-t2-hil/stage-log /usr/libexec/bluefin-t2-hil/smoke-test; do
        [[ ! -e "$f" ]] || fail "release image carries harness helper: $f"
    done
    for u in early userspace test; do
        [[ ! -e "/usr/lib/systemd/system/bluefin-t2-hil-${u}.service" ]] \
            || fail "release image carries harness unit: bluefin-t2-hil-${u}.service"
    done
    for w in /etc/systemd/system/sysinit.target.wants/bluefin-t2-hil-early.service \
             /etc/systemd/system/multi-user.target.wants/bluefin-t2-hil-userspace.service \
             /etc/systemd/system/multi-user.target.wants/bluefin-t2-hil-test.service; do
        [[ ! -e "$w" ]] || fail "release image enables a harness unit: $w"
    done
    pass "release image carries no harness surface"
else
    for s in /usr/libexec/bluefin-t2-hil/stage-log /usr/libexec/bluefin-t2-hil/smoke-test; do
        [[ -x "$s" ]] || fail "missing or not executable: $s"
    done
    for u in early userspace test; do
        f="/usr/lib/systemd/system/bluefin-t2-hil-${u}.service"
        [[ -f "$f" ]] || fail "missing harness unit: $f"
    done
    for w in /etc/systemd/system/sysinit.target.wants/bluefin-t2-hil-early.service \
             /etc/systemd/system/multi-user.target.wants/bluefin-t2-hil-userspace.service \
             /etc/systemd/system/multi-user.target.wants/bluefin-t2-hil-test.service; do
        [[ -L "$w" ]] || fail "missing enable symlink: $w (the units must be enabled at build time)"
    done
    MODEL_FILE="/usr/share/bluefin-t2/models.d/MacBookPro16,2.toml"
    [[ -f "$MODEL_FILE" ]] || fail "models.d missing for MacBookPro16,2 — the smoke test would fail with models.d-missing"
    pass "harness units, stage loggers, smoke test and models.d present"
fi

echo "== 11. the T2 units, the system-side provisioning contract, and no pkexec =="
# T7 of the design, corrected 2026-10-22. Group provisioning is a ROOT system service. The
# original per-user unit called pkexec, and a systemd --user service is not a logind
# session, so a polkit action with allow_active=yes never authorised it: the greeter failed
# on SHELL, the real user got "Not authorized", and the group was never added. A root
# oneshot plus a path unit on /etc/passwd needs no policy and cannot race the session.
SYSD=/usr/lib/systemd/system
OUR_SYSTEM_UNITS=(bluefin-t2-firmware-import.service bluefin-t2-firmware-import.path
                  bluefin-t2-nm-bridge.service bluefin-t2-dsp.service
                  bluefin-t2-user-groups.service bluefin-t2-user-groups.path)
for u in "${OUR_SYSTEM_UNITS[@]}"; do
    [[ -f "$SYSD/$u" ]] || fail "missing unit: $SYSD/$u"
    systemd-analyze verify "$SYSD/$u" || fail "systemd-analyze verify failed: $u"
done
mapfile -t found_units < <(find "$SYSD" /usr/lib/systemd/user -maxdepth 1 -name 'bluefin-t2-*' \
    ! -name 'bluefin-t2-hil-*' -printf '%f\n' | sort)
mapfile -t expected_units < <(printf '%s\n' "${OUR_SYSTEM_UNITS[@]}" | sort)
[[ "${found_units[*]}" == "${expected_units[*]}" ]] \
    || fail "our unit set is not the named six: ${found_units[*]}"

# The blacklist must be silent, and the Touch Bar must not run in the greeter session.
# Both are inherited behaviours the host has and the first bench boots did not: ~40
# "Module X is blacklisted" KERN_ERR lines per boot, and nine Touch Bar restarts with
# /dev/dri/card0 permission denied (2026-10-22).
SILENT=/etc/modprobe.d/kait2en-silent-blacklist.conf
[[ -f "$SILENT" ]] || fail "missing $SILENT: boots print 'Module X is blacklisted'"
karg_mods=$(grep -o 'module_blacklist=[^"]*' /usr/lib/bootc/kargs.d/00-t2.toml \
    | cut -d= -f2 | tr ',' ' ')
for m in $karg_mods; do
    grep -qx "install $m /bin/true" "$SILENT" \
        || fail "silent blacklist misses $m (module_blacklist and modprobe.d disagree)"
done
[[ "$(grep -c '^install ' "$SILENT")" -eq "$(wc -w <<<"$karg_mods")" ]] \
    || fail "silent blacklist has entries not in module_blacklist"
TOUCHBAR_DROPIN=/usr/lib/systemd/user/kait2en-touchbar.service.d/10-bluefin-t2-greeter.conf
[[ -f "$TOUCHBAR_DROPIN" ]] || fail "missing the Touch Bar greeter drop-in"
grep -qx 'ConditionUser=!gdm-greeter' "$TOUCHBAR_DROPIN" \
    || fail "the Touch Bar unit would run in the greeter session and restart on /dev/dri/card0"
pass "blacklisted modules are silent and the Touch Bar unit skips the greeter"
for f in "${OUR_SYSTEM_UNITS[@]/#/$SYSD/}" \
         /usr/lib/systemd/system-preset/80-bluefin-t2.preset \
         /usr/lib/sysusers.d/80-bluefin-t2.conf \
         /etc/NetworkManager/conf.d/10-t2-services.conf \
         /usr/share/bluefin-t2/models.d/MacBookPro16,2.toml \
         /usr/lib/bootc/kargs.d/00-t2.toml \
         /usr/lib/dracut/dracut.conf.d/90-t2-input.conf \
         /usr/lib/modules-load.d/90-t2.conf; do
    [[ "$(stat -c %a "$f")" == 644 ]] || fail "mode must be 0644: $f"
done
for h in /usr/libexec/bluefin-t2/user-groups /usr/libexec/bluefin-t2/firmware-import \
         /usr/libexec/bluefin-t2/nm-bridge; do
    [[ "$(stat -c %a "$h")" == 755 ]] || fail "helper mode must be 0755: $h"
    [[ ! -u "$h" ]] || fail "helper must not be setuid: $h"
done
pass "5 units present, named set exact, modes 0644/0755, systemd-analyze verify clean"

# The old privilege path is gone and nothing replaced it: a root system service needs no
# pkexec and no polkit action.
[[ ! -e /usr/share/polkit-1/actions/org.bluefin_t2.provision-user.policy ]] \
    || fail "the old polkit action is still shipped"
[[ ! -e /usr/libexec/bluefin-t2/provision-user ]] \
    || fail "the old pkexec helper is still shipped"
# Check execution, not the word: our own comments say "no pkexec", and this gate file
# contains the search string. Strip comments and skip the gate script itself.
for f in "$SYSD"/*.service "$SYSD"/*.path /usr/libexec/bluefin-t2/*; do
    [[ -f "$f" ]] || continue
    [[ "$f" == */90-tests.sh ]] && continue
    if sed 's/#.*//' "$f" | grep -q 'pkexec'; then
        fail "a runtime surface still invokes pkexec: $f"
    fi
done

GROUPS_SVC="$SYSD/bluefin-t2-user-groups.service"
GROUPS_PATH="$SYSD/bluefin-t2-user-groups.path"
grep -qxF 'ExecStart=/usr/libexec/bluefin-t2/user-groups' "$GROUPS_SVC" \
    || fail "user-groups.service must run the helper"
grep -qxF 'Type=oneshot' "$GROUPS_SVC" || fail "user-groups.service must be oneshot"
grep -qxF 'PathChanged=/etc/passwd' "$GROUPS_PATH" || fail "the path unit must watch /etc/passwd"
grep -qxF 'Unit=bluefin-t2-user-groups.service' "$GROUPS_PATH" \
    || fail "the path unit must trigger the service"
[[ -L /etc/systemd/system/multi-user.target.wants/bluefin-t2-user-groups.service ]] \
    || fail "missing enable symlink for user-groups.service"
[[ -L /etc/systemd/system/paths.target.wants/bluefin-t2-user-groups.path ]] \
    || fail "missing enable symlink for user-groups.path"
grep -qx 'enable bluefin-t2-user-groups.service' /usr/lib/systemd/system-preset/80-bluefin-t2.preset \
    || fail "the preset must enable user-groups.service"
grep -qx 'enable bluefin-t2-user-groups.path' /usr/lib/systemd/system-preset/80-bluefin-t2.preset \
    || fail "the preset must enable user-groups.path"

# Executable behaviour without touching the image: a fixture passwd with one human user.
FIXP="$(mktemp)"
printf 'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:nobody:/:/usr/sbin/nologin\ntesthuman:x:1000:1000:Test:/home/testhuman:/bin/bash\n' > "$FIXP"
dry="$(BLUEFIN_T2_PASSWD="$FIXP" /usr/libexec/bluefin-t2/user-groups --dry-run 2>&1)" \
    || { rm -f "$FIXP"; fail "user-groups --dry-run failed"; }
rm -f "$FIXP"
grep -q 'would add testhuman to kait2en-touchbar' <<<"$dry" \
    || fail "user-groups does not see the human user: $dry"
if grep -q 'nobody' <<<"$dry"; then fail "user-groups must skip system accounts"; fi
pass "provisioning is a root system service: no pkexec, path unit on /etc/passwd, dry-run sees only humans"

# --- firmware import: the marker condition, and a watched path that is not the output --
IMPORT_SVC="$SYSD/bluefin-t2-firmware-import.service"
IMPORT_PATH="$SYSD/bluefin-t2-firmware-import.path"
grep -qxF 'ConditionPathExists=/boot/efi/kait2en/firmware/wifi/SHA256SUMS' "$IMPORT_SVC" \
    || fail "import must be conditioned on the writer's SHA256SUMS marker"
grep -qxF 'PathExists=/boot/efi/kait2en/firmware/wifi/SHA256SUMS' "$IMPORT_PATH" \
    || fail "the .path unit must watch the incoming SHA256SUMS"
grep -qxF 'Unit=bluefin-t2-firmware-import.service' "$IMPORT_PATH" \
    || fail "the .path unit must trigger the import service"
if grep -qE '^Path(Exists|Changed)=.*/var/lib/(firmware|bluefin-t2)' "$IMPORT_PATH"; then
    fail "the .path unit watches the service's own output and can re-trigger on it"
fi
[[ -x /usr/libexec/bluefin-t2/firmware-import ]] || fail "missing firmware-import helper"
pass "firmware import: SHA256SUMS condition, watched path separate from its output"

# --- enablement: the declarative presets and the symlinks they name -------------------
for w in /etc/systemd/system/multi-user.target.wants/bluefin-t2-firmware-import.service \
         /etc/systemd/system/multi-user.target.wants/bluefin-t2-firmware-import.path \
         /etc/systemd/system/multi-user.target.wants/bluefin-t2-nm-bridge.service \
         /etc/systemd/system/multi-user.target.wants/bluefin-t2-user-groups.service \
         /etc/systemd/system/paths.target.wants/bluefin-t2-user-groups.path; do
    [[ -L "$w" ]] || fail "missing enable symlink: $w"
done
grep -qxF 'enable bluefin-t2-firmware-import.service' /usr/lib/systemd/system-preset/80-bluefin-t2.preset \
    || fail "system preset does not enable the import service"
grep -qxF 'enable bluefin-t2-firmware-import.path' /usr/lib/systemd/system-preset/80-bluefin-t2.preset \
    || fail "system preset does not enable the import path unit"
grep -qxF 'enable bluefin-t2-nm-bridge.service' /usr/lib/systemd/system-preset/80-bluefin-t2.preset \
    || fail "system preset does not enable the bridge unit"
grep -qxF 'enable bluefin-t2-user-groups.service' /usr/lib/systemd/system-preset/80-bluefin-t2.preset \
    || fail "system preset does not enable user-groups.service"
grep -qxF 'enable bluefin-t2-user-groups.path' /usr/lib/systemd/system-preset/80-bluefin-t2.preset \
    || fail "system preset does not enable user-groups.path"
systemctl --root=/ preset-all --dry-run >/dev/null 2>&1 \
    || fail "systemctl --root=/ preset-all --dry-run failed"
pass "presets and enable symlinks agree"

# --- the T2 CDC-NCM profile must autoconnect ------------------------------------------
# 2026-10-22: the first helper created the profile with autoconnect=no, so the link never
# came up, IPv6 never appeared, and both t2remote and the Touch ID bridge waited forever.
NM_BRIDGE=/usr/libexec/bluefin-t2/nm-bridge
grep -q 'connection.autoconnect yes' "$NM_BRIDGE" \
    || fail "nm-bridge must create/reconcile an autoconnecting profile"
grep -q 'ipv6.method link-local' "$NM_BRIDGE" \
    || fail "nm-bridge must set ipv6.method link-local"
# The profile ships as a file so NetworkManager sees it before it starts. Creating it at
# runtime left the first boot without an active link for ~20 minutes (2026-10-22), and a
# manual up from the helper was the wrong fix: it blocked, failed, and was never retried.
NM_PROFILE=/etc/NetworkManager/system-connections/t2-ncm.nmconnection
[[ -f "$NM_PROFILE" ]] || fail "the NCM profile must ship at $NM_PROFILE"
[[ "$(stat -c %a "$NM_PROFILE")" == 600 ]] || fail "the NCM profile must be mode 0600"
grep -qx 'autoconnect=true' "$NM_PROFILE" || fail "the shipped NCM profile must autoconnect"
grep -qx 'method=link-local' "$NM_PROFILE" || fail "the shipped NCM profile must use IPv6 link-local"
grep -qi '^mac-address=ac:de:48:00:11:22$' "$NM_PROFILE" || fail "the shipped NCM profile MAC is wrong"
grep -q 'nmcli connection modify' "$NM_BRIDGE" || fail "nm-bridge must reconcile the shipped profile"
if grep -E '^[^#]*nmcli .*connection up' "$NM_BRIDGE" >/dev/null; then
    fail "nm-bridge must not activate the link itself (it blocks and NM does not retry it)"
fi
pass "T2 CDC-NCM profile autoconnects with IPv6 link-local"

# --- the device group the helper joins -------------------------------------------------
grep -qxF 'g kait2en-touchbar - -' /usr/lib/sysusers.d/80-bluefin-t2.conf \
    || fail "sysusers.d entry for kait2en-touchbar missing"
getent group kait2en-touchbar >/dev/null || fail "kait2en-touchbar group was not materialised"
for h in user-groups firmware-import nm-bridge; do
    bash -n "/usr/libexec/bluefin-t2/$h" || fail "shell syntax error in $h"
done
pass "kait2en-touchbar group materialised; helper scripts parse"

echo "== 12. bluefin-t2 report and the expectation set =="
REPORT=/usr/bin/bluefin-t2
[[ -x "$REPORT" ]] || fail "missing $REPORT — step 03 did not install the userspace RPM"
help_text="$("$REPORT" --help)"
grep -q 'bluefin-t2 report' <<<"$help_text" || fail "help does not document the report subcommand"

# The expectation set is data, and its shape is a property: four models, each naming the
# 18 objects exactly once across its categories, with the measured split only on 16,2.
MODELS=/usr/share/bluefin-t2/models.d
python3 - "$MODELS" <<'PY' || fail "models.d failed its schema check"
import pathlib, sys, tomllib

CANON = {
    "t2bce_dma", "t2bce_core", "t2bce_vhci", "t2bce_audio", "t2bce_ave",
    "t2hid", "t2touchbar_bl", "t2touchbar_kbd",
    "hid_t2magicmouse",
    "t2bdrm", "t2smc", "t2sbs", "t2mfi_fastcharge", "t2gmux", "t2thunderbolt", "t2smp",
    "t2_precision_trackpad", "t2_trackpad_actuator",
}
root = pathlib.Path(sys.argv[1])
files = sorted(root.glob("*.toml"))
if len(files) != 4:
    raise SystemExit(f"expected 4 model files, found {len(files)}")
for f in files:
    d = tomllib.loads(f.read_text())
    status = d.get("status")
    if status not in ("validated", "validation-set", "argument"):
        raise SystemExit(f"{f.name}: bad status {status!r}")
    names = [n for k in ("expected_loaded", "expected_unbound", "expected_absent", "unmeasured")
             for n in d.get(k, [])]
    if len(names) != 18 or set(names) != CANON:
        raise SystemExit(f"{f.name}: does not name the 18 objects exactly once ({len(names)} names)")
    if f.stem == "MacBookPro16,2":
        if d.get("unmeasured"):
            raise SystemExit("MacBookPro16,2 must have no unmeasured objects")
        if set(d.get("expected_unbound", [])) != {"hid_t2magicmouse"}:
            raise SystemExit("MacBookPro16,2 expected_unbound must be exactly hid_t2magicmouse")
        if set(d.get("expected_absent", [])) != {"t2gmux"}:
            raise SystemExit("MacBookPro16,2 expected_absent must be exactly t2gmux")
    else:
        if set(d.get("unmeasured", [])) != {"hid_t2magicmouse", "t2gmux"}:
            raise SystemExit(f"{f.name}: the two measured states must be unmeasured")
print(f"models.d: {len(files)} files, 18 objects each, statuses valid")
PY
pass "models.d: 4 files, 18 objects each, measured split only on 16,2"

# Tier 0 fixtures: the same binary must produce 0, 1 and 2. The fixture tree is removed
# before lint runs; nothing under it survives.
FIX="$(mktemp -d)"
mkdir -p "$FIX/sys/devices/virtual/dmi/id" "$FIX/sys/module" "$FIX/usr/share/bluefin-t2" \
         "$FIX/var/lib/bluefin-t2" "$FIX/proc/sys/kernel"
printf 'MacBookPro16,2\n' > "$FIX/sys/devices/virtual/dmi/id/product_name"
cp -a "$MODELS" "$FIX/usr/share/bluefin-t2/"
for m in t2bce_dma t2bce_core t2bce_vhci t2bce_audio t2bce_ave t2hid t2touchbar_bl \
         t2touchbar_kbd t2bdrm t2smc t2smp t2sbs t2thunderbolt t2mfi_fastcharge \
         t2_precision_trackpad t2_trackpad_actuator hid_t2magicmouse; do
    mkdir -p "$FIX/sys/module/$m"
done
printf 'payload_sha256=fixture\n' > "$FIX/var/lib/bluefin-t2/firmware.state"
printf '7.2.5-200.fc44.x86_64\n' > "$FIX/proc/sys/kernel/osrelease"

json_out="$("$REPORT" report --root "$FIX" --json)" || { rm -rf "$FIX"; fail "fixture 0: expected exit 0"; }
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"]==1 and d["exit_code"]==0 and d["verdict"]=="ok" and d["model"]["class"]=="validated", d' <<<"$json_out" \
    || { rm -rf "$FIX"; fail "fixture 0: JSON is not the documented contract"; }
md_out="$("$REPORT" report --root "$FIX" --markdown)"
grep -q '^# bluefin-t2 report' <<<"$md_out" || { rm -rf "$FIX"; fail "fixture 0: markdown body missing"; }

rm -rf "$FIX/sys/module/t2smc"
rc=0; "$REPORT" report --root "$FIX" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] || { rm -rf "$FIX"; fail "fixture 1 (missing module): expected exit 1, got $rc"; }

printf 'MacBookPro18,9\n' > "$FIX/sys/devices/virtual/dmi/id/product_name"
rc=0; "$REPORT" report --root "$FIX" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] || { rm -rf "$FIX"; fail "fixture 2 (unknown model): expected exit 2, got $rc"; }
rm -rf "$FIX"
pass "report: exit 0 / 1 / 2 on fixtures, JSON and markdown contract intact"

echo "== 13. the eight apps and t2remote =="
# The confirmed class-A set (design §5 B3; the design names the count, the set was
# confirmed 2026-10-21): six GTK apps, the two power tools, and t2remote.
APP_RPMS=(t2-touchbar t2-fan-control t2-smc-control t2-zone-power t2-force-click
          t2-debug t2-power-explorer t2-power-tune t2remote)
for p in "${APP_RPMS[@]}"; do
    rpm -q "$p" >/dev/null 2>&1 || fail "app RPM not installed: $p"
done
for b in kait2en-touchbar t2-fancontrol-gtk t2-smc-control t2-zonepower-gtk t2-force-click \
         t2-debug t2debug t2-power-explorer t2-power-tune t2remote; do
    [[ -x "/usr/bin/$b" ]] || fail "missing executable /usr/bin/$b"
done

# The desktop entries are data the session reads; validate them rather than trusting them.
for d in /usr/share/applications/org.t2*.desktop; do
    desktop-file-validate "$d" || fail "desktop-file-validate failed: $d"
    # desktop-file-validate checks the file's shape; this checks that its Exec target
    # exists. Upstream hardcodes /usr/local/bin in Exec=, which this image does not have,
    # so the staging renders it to /usr/bin and this is the assertion that it worked.
    exec_line="$(awk -F= '/^Exec=/{print substr($0,6); exit}' "$d")"
    [[ -n "$exec_line" ]] || fail "desktop entry has no Exec=: $d"
    exec_target="${exec_line%% *}"
    if [[ "$exec_target" == */* ]]; then
        [[ -x "$exec_target" ]] || fail "desktop entry $d execs a missing binary: $exec_target"
    else
        command -v "$exec_target" >/dev/null \
            || fail "desktop entry $d execs a binary not on PATH: $exec_target"
    fi
done

# The inherited daemons, their units and their enablement. Upstream's units order
# themselves After=multi-user.target while being WantedBy=multi-user.target; that cycle is
# removed at packaging time, and this asserts it does not come back.
APP_UNITS=(t2-fancontrol t2-smc-gaugingd t2-zonepowerd t2-force-click
           kait2en-touchbar-attach kait2en-t2-remote)
for u in "${APP_UNITS[@]}"; do
    systemd-analyze verify "/usr/lib/systemd/system/$u.service" || fail "systemd-analyze verify failed: $u"
    if grep -qx 'After=multi-user.target' "/usr/lib/systemd/system/$u.service"; then
        fail "$u still orders itself after multi-user.target (an ordering cycle)"
    fi
    [[ -L "/etc/systemd/system/multi-user.target.wants/$u.service" ]] \
        || fail "missing enable symlink for $u"
done
systemd-analyze verify /usr/lib/systemd/user/kait2en-touchbar.service \
    || fail "systemd-analyze verify failed: kait2en-touchbar (user)"
[[ -L /etc/systemd/user/graphical-session.target.wants/kait2en-touchbar.service ]] \
    || fail "missing enable symlink for kait2en-touchbar (user)"

# The two power tools' polkit actions are declarative; parse them here. pkaction needs the
# booted authority, so the exec.path/allow_active assertions for OUR action stay in gate 11.
for p in org.t2powertune org.t2powerexplorer; do
    xmllint --noout "/usr/share/polkit-1/actions/$p.policy" \
        || fail "polkit policy is not well-formed XML: $p"
done
udevadm verify /usr/lib/udev/rules.d/99-zz-kait2en-touchbar.rules \
    || fail "udevadm verify failed for the Touch Bar rule"

pass "9 app RPMs: binaries, desktop entries, units, enablement, polkit actions and udev rule"

echo "== 14. SELinux policy, PAM fingerprint, icon cache, and the build-time-only tools =="
# The policy module is installed at priority 400 (step 04). `semodule -lfull` prints
# "<priority> <name> <kind>"; a module that failed to install is simply absent.
semodule -lfull 2>/dev/null | awk '$1 == 400 && $2 == "kait2en-t2-touchid" { found = 1 } END { exit !found }' \
    || fail "SELinux module kait2en-t2-touchid is not installed at priority 400"

# Fingerprint auth is enabled through authselect, which writes the stack. The design says
# "system-auth and password-auth"; authselect's with-fingerprint feature writes the auth
# stack (system-auth) only — password-auth is the password-change stack and takes no
# fingerprint. Assert what the tool actually produces, and record the correction.
grep -q 'pam_fprintd\.so' /etc/pam.d/system-auth \
    || fail "/etc/pam.d/system-auth has no pam_fprintd.so (with-fingerprint not applied)"
authselect current 2>/dev/null | grep -qx -- '- with-fingerprint' \
    || fail "authselect does not report the with-fingerprint feature"

[[ -f /usr/share/icons/hicolor/icon-theme.cache ]] \
    || fail "the hicolor icon cache was not built (step 05)"

# Policy assertion, phrased negatively: no runtime unit, helper or hook may invoke a
# build-time-only tool. semodule runs in the image build by design, never at runtime.
# The gate script itself is excluded: it is build-time harness, removed by step 07 after
# this run, and it contains the very words this search is looking for.
if grep -lE '\b(semodule|semodule_package|grubby|dkms)\b' \
        /usr/libexec/bluefin-t2/user-groups \
        /usr/libexec/bluefin-t2/firmware-import \
        /usr/libexec/bluefin-t2/nm-bridge \
        /usr/lib/systemd/system/*.service /usr/lib/systemd/user/*.service 2>/dev/null; then
    fail "a runtime surface invokes semodule/grubby/dkms"
fi
pass "SELinux module at 400, PAM fingerprint on the auth stack, icon cache built, no build-time tool at runtime"

echo "== 15. the shipped docs =="
for f in /usr/share/bluefin-t2/MODELS.md /usr/share/bluefin-t2/RECOVERY.md; do
    [[ -s "$f" ]] || fail "missing shipped doc: $f"
done
# All four models are named, and exactly one is marked validated. This is the overclaim
# guard in document form: a second "validated" in MODELS.md is a model claim made without
# a Tier 2 run for that model.
for m in 'MacBookPro16,2' 'MacBookPro15,2' 'MacBookPro15,4' 'MacBookPro16,3'; do
    grep -q "$m" /usr/share/bluefin-t2/MODELS.md || fail "MODELS.md does not name $m"
done
validated_count="$(grep -c '\*\*validated\*\*' /usr/share/bluefin-t2/MODELS.md || true)"
[[ "$validated_count" -eq 1 ]] \
    || fail "MODELS.md marks $validated_count models validated; exactly one (16,2) has a recorded Tier 2 run"
# Recovery must carry the two rules whose absence would be dangerous: never unload the
# input modules, and the supported way back is a rollback, not a hand-fix.
grep -q 'Never unload' /usr/share/bluefin-t2/RECOVERY.md \
    || fail "RECOVERY.md does not state the never-unload rule"
grep -q 'bootc rollback' /usr/share/bluefin-t2/RECOVERY.md \
    || fail "RECOVERY.md does not name the rollback path"
grep -q 'firmware_class.path' /usr/share/bluefin-t2/RECOVERY.md \
    || fail "RECOVERY.md does not name the firmware channel"
pass "MODELS.md names four models with one validated; RECOVERY.md carries the recovery rules"

echo "== 16. the hub =="
# The page model is built from the documented JSON contract with no display and no GTK
# initialisation. Nine named pages, each with rows, is the whole headless claim.
hub_out="$(bluefin-t2 --check-gui 2>&1)" || fail "hub model does not accept this machine's report: $hub_out"
grep -q '^hub: 9 pages, [1-9][0-9]* rows, verdict ' <<<"$hub_out" \
    || fail "hub page model is not the nine-page contract: $hub_out"
# Exit 2 (unsupported model) is still a valid document and must render. A fixture with an
# unknown product name is the cheapest way to prove the hub does not mistake a soft verdict
# for a contract failure.
FIX="$(mktemp -d)"
mkdir -p "$FIX/sys/devices/virtual/dmi/id" "$FIX/usr/share/bluefin-t2/models.d"
printf 'MacBookPro18,9\n' > "$FIX/sys/devices/virtual/dmi/id/product_name"
hub_rc=0; bluefin-t2 --check-gui --root "$FIX" >/dev/null 2>&1 || hub_rc=$?
rm -rf "$FIX"
[[ "$hub_rc" -eq 0 ]] || fail "hub rejects the unsupported-model document (exit 2): rc=$hub_rc"
# The hub is not a stub: the binary must link GTK, and its desktop entry must launch it.
ldd /usr/bin/bluefin-t2 | grep -q 'libgtk-4\.so' || fail "hub binary does not link GTK"
desktop-file-validate /usr/share/applications/org.bluefin_t2.Hub.desktop \
    || fail "the hub desktop entry does not validate"
hub_exec="$(awk -F= '/^Exec=/{print substr($0,6); exit}' /usr/share/applications/org.bluefin_t2.Hub.desktop)"
[[ -x "$hub_exec" ]] || fail "the hub desktop entry execs a missing binary: $hub_exec"
pass "hub: nine pages headless, exit-2 document accepted, GTK linked, desktop entry resolves"

echo "== 17. the public signing certificate =="
# The DER shipped in the image must be the certificate that signed these modules, or a
# successful mokutil --import would enrol a key that verifies nothing. modinfo's signer is
# the certificate subject; the checksum pins the file to the build's own signer.
DER=/etc/pki/akmods/certs/bluefin-t2.der
[[ -s "$DER" ]] || fail "no public signing certificate at $DER"
openssl x509 -in "$DER" -inform DER -noout -subject >/dev/null 2>&1 \
    || fail "the shipped DER does not parse as an X.509 certificate"
der_cn="$(openssl x509 -in "$DER" -inform DER -noout -subject -nameopt sep_multiline \
    | sed -n 's/^ *CN=//p' | head -1)"
[[ -n "$der_cn" ]] || fail "the shipped certificate has no CN"
for ko in "${our_kos[@]}"; do
    signer="$(modinfo -F signer "$ko" 2>/dev/null || true)"
    [[ "$signer" == "$der_cn" ]] \
        || fail "$(basename "$ko") signer '$signer' does not match the shipped certificate CN '$der_cn'"
done
want="$(cut -d' ' -f1 /usr/share/bluefin-t2/certs/bluefin-t2.der.sha256)"
got="$(sha256sum "$DER" | cut -d' ' -f1)"
[[ "$want" == "$got" ]] || fail "the shipped DER is not the build's signing certificate"
pass "public signing certificate matches all ${#our_kos[@]} module signers"

echo "== 18. the Touch ID bridge and the audio DSP =="
# Touch ID: with only PAM+fprintd and no bridge, `fprintd-enroll` answers "No devices
# available" (observed 2026-10-22). The bridge is what makes the macOS-enrolled finger
# usable on Linux, so its binary, unit, D-Bus policy and config are all required.
rpm -q t2-touchid t2-dsp >/dev/null 2>&1 || fail "t2-touchid or t2-dsp is not installed"
[[ -x /usr/bin/t2-touchid ]] || fail "missing /usr/bin/t2-touchid"
systemd-analyze verify /usr/lib/systemd/system/kait2en-t2-touchid.service \
    || fail "systemd-analyze verify failed: kait2en-t2-touchid"
[[ -s /etc/kait2en/t2-touchid.conf ]] || fail "missing /etc/kait2en/t2-touchid.conf"
grep -qx 'T2_TOUCHID_BIND_USER=none' /etc/kait2en/t2-touchid.conf \
    || fail "the shipped config must leave binding to user-groups (T2_TOUCHID_BIND_USER=none)"
[[ -s /usr/lib/systemd/system/fprintd.service.d/kait2en-t2-touchid.conf ]] \
    || fail "missing the fprintd drop-in"
[[ -s /usr/share/dbus-1/system.d/org.kait2en.TouchId.conf ]] \
    || fail "missing the D-Bus policy"
# The DSP is host-side graphs, not Apple firmware: profiles, udev rule and WirePlumber
# wiring, plus the LV2 plugins the graphs load.
[[ -s /usr/share/t2-dsp/models.json ]] || fail "missing /usr/share/t2-dsp/models.json"
for p in 16_2 15_2 15_4 16_3; do
    [[ -s "/usr/share/t2-dsp/profiles/$p/graph.json" ]] \
        || fail "missing DSP profile $p graph.json"
done
[[ -s /usr/share/t2-dsp/profiles/16_2/XTC-side-44k.wav ]] \
    || fail "missing the 16_2 crosstalk FIR"
[[ -s /usr/lib/udev/rules.d/89-t2-dsp.rules ]] || fail "missing the DSP udev rule"
udevadm verify /usr/lib/udev/rules.d/89-t2-dsp.rules || fail "udevadm verify failed for the DSP rule"
[[ -s /usr/share/wireplumber/wireplumber.conf.d/51-t2-dsp.conf ]] \
    || fail "missing the WirePlumber DSP config"
[[ -s /usr/share/wireplumber/scripts/t2-default-output.lua ]] \
    || fail "missing the WirePlumber default-output script"
rpm -q pipewire-module-filter-chain-lv2 lv2-bankstown lsp-plugins-lv2 >/dev/null 2>&1 \
    || fail "the DSP runtime plugins are not installed"
pass "Touch ID bridge packaged; DSP profiles, udev and WirePlumber wiring present with runtime plugins"

# The DSP graph must be chosen on the machine, not baked: the build host's DMI is not the
# user's, so a graph in /etc at build time would be wrong on three of the four models.
[[ ! -e /etc/pipewire/pipewire.conf.d/51-t2-dsp.conf ]] \
    || fail "a DSP graph is baked into the image; it must be selected at boot per model"
[[ -x /usr/libexec/bluefin-t2/dsp-select ]] || fail "missing /usr/libexec/bluefin-t2/dsp-select"
[[ -f /etc/systemd/system/multi-user.target.wants/bluefin-t2-dsp.service ]] \
    || fail "bluefin-t2-dsp.service is not enabled"
grep -qx 'enable bluefin-t2-dsp.service' /usr/lib/systemd/system-preset/80-bluefin-t2.preset \
    || fail "bluefin-t2-dsp.service is not in the preset"
fixture=$(mktemp -d)
mkdir -p "$fixture/etc/pipewire/pipewire.conf.d" \
         "$fixture/usr/share/t2-dsp/pipewire" "$fixture/var/lib/bluefin-t2"
cp /usr/share/t2-dsp/models.json "$fixture/usr/share/t2-dsp/"
cp /usr/share/t2-dsp/pipewire/16_2.conf "$fixture/usr/share/t2-dsp/pipewire/"
printf 'MacBookPro16,2\n' > "$fixture/dmi"
/usr/libexec/bluefin-t2/dsp-select --root "$fixture" --dmi-file "$fixture/dmi" \
    || fail "dsp-select failed on the 16,2 fixture"
cmp -s "$fixture/etc/pipewire/pipewire.conf.d/51-t2-dsp.conf" \
       "$fixture/usr/share/t2-dsp/pipewire/16_2.conf" \
    || fail "dsp-select installed the wrong graph for 16,2"
grep -q '^16_2 ' "$fixture/var/lib/bluefin-t2/dsp.state" \
    || fail "dsp-select did not record the installed profile"
printf 'MacPro7,1\n' > "$fixture/dmi-unknown"
/usr/libexec/bluefin-t2/dsp-select --root "$fixture" --dmi-file "$fixture/dmi-unknown" \
    || fail "dsp-select must exit 0 on an unsupported model"
[[ ! -e "$fixture/etc/pipewire/pipewire.conf.d/51-t2-dsp.conf" ]] \
    || fail "dsp-select left its graph installed after the model became unsupported"
rm -rf "$fixture"
pass "DSP graph selected per model at boot (16,2 installed, unsupported model withdrawn, no graph baked)"

# The post-setup dialog that mirrors KaiT2EN's one-reboot first boot.
[[ -x /usr/libexec/bluefin-t2/first-run ]] || fail "missing the first-run dialog helper"
[[ -f /etc/xdg/autostart/bluefin-t2-first-run.desktop ]] \
    || fail "the first-run dialog is not autostarted"
grep -qx 'X-GNOME-Autostart-enabled=true' /etc/xdg/autostart/bluefin-t2-first-run.desktop \
    || fail "the first-run autostart entry is disabled"
fr_home=$(mktemp -d)
fr_out=$(HOME="$fr_home" /usr/libexec/bluefin-t2/first-run --check 2>&1) \
    || fail "first-run --check failed: ${fr_out}"
grep -q '^first-run: ' <<<"$fr_out" || fail "first-run --check gave no verdict: ${fr_out}"
rm -rf "$fr_home"
pass "first-run dialog and autostart present, --check gives a verdict"

# Last, because every gate above may leave something behind: `bootc container lint` runs
# after this script and correctly flags content in /run and /var. The private polkit
# authority and systemd-analyze's unit-load markers are build-time test fixtures, not image
# content. Only the paths the gates create are removed; /run/systemd/resolve is a runtime
# mount, so the rmdir is best-effort and lint is the real check.
rm -rf /run/dbus /var/lib/polkit-1 /run/systemd/ask-password 2>/dev/null || true
rm -f /run/systemd/systemd-units-load 2>/dev/null || true
rmdir /run/systemd 2>/dev/null || true

echo "ALL TIER 0 GATES PASSED for ${KVER}"
