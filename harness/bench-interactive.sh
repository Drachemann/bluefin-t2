#!/usr/bin/env bash
# bench-interactive.sh — one command for the interactive half of the Tier 2 bench.
#
# Copy this to the results stick and run it ON THE BOOTED BENCH SYSTEM after booting with
#
#     systemd.mask=bluefin-t2-hil-test.service
#
# on the GRUB linux line (so the smoke-test unit does not power the machine off).
#
# It records identity and evidence, checks the desktop user is in kait2en-touchbar (and
# fixes it, then asks for a re-login), runs the installed interactive checks, writes the
# firmware import marker the old provision script missed, runs `bluefin-t2 report`, and
# prints the human checklist. Everything goes to interactive-<run-id>.log on the stick.

set -uo pipefail

STICK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RUN_ID=$(cat "$STICK_DIR/CURRENT" 2>/dev/null | tr -d '[:space:]' || true)
[[ -n ${RUN_ID:-} ]] || RUN_ID="interactive-$(date +%Y%m%dT%H%M%S)"
OUT="$STICK_DIR/interactive-$RUN_ID.log"
if ! touch "$OUT" 2>/dev/null; then
  OUT="$HOME/bench-interactive-$RUN_ID.log"
  printf 'results stick is not writable; logging to %s\n' "$OUT"
else
  printf 'logging to %s\n' "$OUT"
fi
exec > >(tee -a "$OUT") 2>&1

section() { printf '\n===== %s =====\n' "$*"; }
note()    { printf '  %s\n' "$*"; }

section "identity"
note "date:      $(date -Is)"
note "user:      ${USER:-unknown} (uid $(id -u))  groups: $(id -nG)"
note "kernel:    $(uname -r)"
note "os:        $(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
note "model:     $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
if command -v bootc >/dev/null 2>&1; then
  bootc status --json 2>/dev/null | tr -d '\n' | grep -oE 'sha256:[0-9a-f]{64}' | head -1 \
    | sed 's/^/  image:     /'
fi
note "results:   $STICK_DIR (run $RUN_ID)"

section "1. desktop user in kait2en-touchbar"
if id -nG | tr ' ' '\n' | grep -qx kait2en-touchbar; then
  note "OK: user is in kait2en-touchbar"
else
  note "MISSING: user is not in kait2en-touchbar — the Touch Bar daemon cannot open its devices."
  note "Adding the group now (this asks for your password):"
  if sudo usermod -aG kait2en-touchbar "$USER"; then
    note "Added. The group is only in a NEW session, so: log out, log in, and run this script again."
    exit 3
  else
    note "Could not add the group. Run manually: sudo usermod -aG kait2en-touchbar \"$USER\""
    exit 3
  fi
fi

section "2. units and services"
for u in t2-fancontrol t2-smc-gaugingd t2-zonepowerd t2-force-click kait2en-touchbar-attach kait2en-t2-remote; do
  note "$(printf '%-28s %s' "$u" "$(systemctl is-active "$u" 2>/dev/null || true)")"
done
note "kait2en-touchbar (user)      $(systemctl --user is-active kait2en-touchbar.service 2>/dev/null || true)"
note "global enablement: $(systemctl --global is-enabled kait2en-touchbar.service 2>/dev/null || true)"
note "--- failed units ---"
systemctl --failed --no-legend --plain 2>/dev/null || true

section "3. hardware surface"
note "--- modules ---"
lsmod 2>/dev/null | awk 'NR == 1 || $1 ~ /^(t2|hid_t2)/' | head -25
note "--- firmware state ---"
if [[ -f /var/lib/bluefin-t2/firmware.state ]]; then cat /var/lib/bluefin-t2/firmware.state; else note "no firmware.state"; fi
note "firmware files: $(find /var/lib/firmware/brcm -maxdepth 1 -type f -name 'brcmfmac*-pcie*' 2>/dev/null | wc -l)"
note "--- input devices ---"
sed -n 's/^N: Name="\(.*\)"$/\1/p' /proc/bus/input/devices 2>/dev/null | grep -iE 'apple|t2|touch|trackpad' || true
note "--- drm ---"
ls -1 /sys/class/drm 2>/dev/null | grep -E '^card[0-9]+' || true
note "--- selinux ---"
semodule -lfull 2>/dev/null | awk '$1 == 400 && $2 == "kait2en-t2-touchid"' || true
note "--- pam fingerprint ---"
grep -q 'pam_fprintd\.so' /etc/pam.d/system-auth && note "pam_fprintd.so present in system-auth" || note "MISSING pam_fprintd.so"
note "--- fingerprint prints (this user) ---"
if command -v fprintd-list >/dev/null 2>&1; then
  fprintd-list "$USER" 2>&1 | sed 's/^/  /' || true
else
  note "fprintd-list not installed"
fi
note "--- audio sinks ---"
if command -v wpctl >/dev/null 2>&1; then
  wpctl status 2>/dev/null | sed -n '/Audio/,/Video/p' | head -15
else
  note "wpctl not available"
fi
note "--- hwmon (fans/thermal) ---"
if compgen -G '/sys/class/hwmon/hwmon*/name' >/dev/null 2>&1; then
  grep -l 't2smc' /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 || note "no t2smc hwmon"
fi

section "4. kernel and journal evidence"
note "--- dmesg: T2 / firmware / brcm (last 60) ---"
sudo dmesg 2>/dev/null | grep -iE 't2|firmware|brcm|Touch Bar' | tail -60 || note "dmesg unavailable"
note "--- journal errors this boot ---"
journalctl -b -p err --no-pager 2>/dev/null | tail -80 || true
note "--- first-login unit ---"
journalctl -b --no-pager -u bluefin-t2-first-login.service 2>/dev/null | tail -20 || true

section "5. installed interactive checks"
if [[ -x /usr/libexec/bluefin-t2-hil/interactive-checks ]]; then
  /usr/libexec/bluefin-t2-hil/interactive-checks --no-write
else
  note "no /usr/libexec/bluefin-t2-hil/interactive-checks on this image"
fi

section "6. firmware import marker (the old provision script missed it)"
if sudo test -s /var/lib/bluefin-t2/firmware.state; then
  note "already present:"
  sudo cat /var/lib/bluefin-t2/firmware.state
else
  if [[ -d /var/lib/firmware/brcm ]]; then
    payload=$( ( cd /var/lib/firmware/brcm && sha256sum brcmfmac*-pcie* 2>/dev/null | sort ) | sha256sum | cut -d' ' -f1)
    files=$(find /var/lib/firmware/brcm -maxdepth 1 -type f -name 'brcmfmac*-pcie*' 2>/dev/null | wc -l | tr -d '[:space:]')
    if (( files > 0 )); then
      sudo mkdir -p /var/lib/bluefin-t2
      printf 'payload_sha256=%s\nsource=bench-interactive\nfiles=%s\n' "$payload" "$files" \
        | sudo tee /var/lib/bluefin-t2/firmware.state >/dev/null
      note "wrote /var/lib/bluefin-t2/firmware.state (files=$files, payload_sha256=$payload)"
    else
      note "no brcmfmac*-pcie* files under /var/lib/firmware/brcm; not writing a marker"
    fi
  else
    note "no /var/lib/firmware/brcm; firmware was not provisioned"
  fi
fi

section "7. the report"
if command -v bluefin-t2 >/dev/null 2>&1; then
  bluefin-t2 report 2>&1 | sed 's/^/  /'
  note "--- report --json saved next to this log ---"
  bluefin-t2 report --json > "$STICK_DIR/report-$RUN_ID.json" 2>/dev/null \
    && note "wrote $STICK_DIR/report-$RUN_ID.json" \
    || note "could not write report JSON to the stick"
  note "--- hub page model ---"
  bluefin-t2 --check-gui 2>&1 | sed 's/^/  /'
else
  note "bluefin-t2 is not installed"
fi

section "8. what only you can check (and record here)"
cat <<'TODO'
  [ ] Touch Bar: shows the bluefin-t2 row, responds to touch; Fn row works.
  [ ] Fingerprint: `fprintd-enroll`, then lock the screen and unlock with it.
  [ ] Audio: play something; internal speakers, then headphones.
  [ ] Suspend: close the lid / `systemctl suspend`; wake; keyboard, trackpad and
      Touch Bar still work; Wi-Fi reconnects.
  [ ] Hub: launch "bluefin-t2" from the app grid; click all nine pages.
  [ ] Write PASS/FAIL for each of the above at the end of this log file,
      then power off.
TODO

section "done"
note "log: $OUT"
