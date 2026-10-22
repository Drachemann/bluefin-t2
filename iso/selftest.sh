#!/usr/bin/bash
# selftest — prove the firmware post-script's behaviour without an installer.
#
# Extracts the body between the firmware-post markers from the kickstart and runs it
# against fixture roots. This is the Tier 0 half of R2-3: it proves copy, checksum refusal,
# empty-source pass-through and the JSON record. The discovery path (mounting the USB ESP by
# marker) and the real Anaconda run are Tier 3.
#
# Usage: iso/selftest.sh

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ks="$here/kickstart/bluefin-t2.ks"
body=$(mktemp)
tmp=$(mktemp -d)
trap 'rm -rf "$body" "$tmp"' EXIT

sed -n '/^# >>> firmware-post$/,/^# <<< firmware-post$/p' "$ks" \
    | sed '1d;$d' > "$body"
[[ -s "$body" ]] || { echo "FATAL: could not extract the firmware post body" >&2; exit 1; }

pass=0
fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }

# --- fixture: a payload as the kit writes it, and a target with an ESP -----------------
payload="$tmp/usb/kait2en/firmware/wifi"
sysroot="$tmp/sysroot"
mkdir -p "$payload" "$sysroot/boot/efi"
printf 'board-specific firmware\n' > "$payload/brcmfmac4364-pcie.apple.trx"
printf 'P-1234\n' > "$payload/P-1234.txt"
( cd "$payload" && sha256sum -- brcmfmac4364-pcie.apple.trx P-1234.txt > SHA256SUMS )

run() { SYSROOT="$sysroot" PAYLOAD="$1" bash "$body" >>"$tmp/log" 2>&1; }

# 1. a good payload is carried, verified and recorded
if run "$payload" \
   && cmp -s "$payload/brcmfmac4364-pcie.apple.trx" "$sysroot/boot/efi/kait2en/firmware/wifi/brcmfmac4364-pcie.apple.trx" \
   && grep -q '"model"' "$sysroot/etc/bluefin-t2/firmware-import.json"; then
    ok "payload copied, checksum-verified and recorded"
else
    bad "payload carry failed: $(tail -2 "$tmp/log")"
fi

# 2. a corrupted payload fails closed and does not ship half a copy
rm -rf "$sysroot/boot/efi/kait2en" "$sysroot/etc/bluefin-t2"
printf 'tampered\n' >> "$payload/brcmfmac4364-pcie.apple.trx"
if run "$payload"; then
    bad "a corrupt payload was accepted"
else
    ok "corrupt payload refused (install fails closed)"
fi

# 3. no payload at all is not an error: the machine must boot and report
: > "$tmp/log"
if run "" && grep -q 'no firmware payload found' "$tmp/log"; then
    ok "absent payload proceeds and says so"
else
    bad "absent payload did not proceed cleanly"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
