#!/bin/bash
# verify-artifacts.sh — the A1 assertion set, runnable on the packaged artifacts alone.
#
# Usage: verify-artifacts.sh <rpm-dir> <kver> <cert.pem> [--record DIR] [--exact] [--no-record]
#
# This is the half of the A1 proof that needs no kernel-devel and no private key: it
# reads the RPMs the build produced, extracts the modules, and asserts every property
# the design makes load-bearing. It runs on the host, on any machine with rpm/kmod/
# openssl, and it is the check `just verify` runs.
#
# What it proves (design §9 Tier 0):
#   * the named 12 RPMs exist and nothing else does;
#   * every RPM declares `kernel-core-uname-r = <kver>` exactly (the structural lock);
#   * the named 18 objects are present, exactly once each, and nothing else;
#   * every object's vermagic equals <kver> (module identity — the project's most
#     common real failure is a module built for the other kernel);
#   * every object is signed PKCS#7, signer CN equals the certificate's CN, and the
#     CMS signature verifies against the certificate — plus a byte-flip control that
#     proves the CMS check is not vacuous;
#   * the payload bytes match the recorded module hashes, when a record dir is given.
#     Two records exist and they mean different things: modules.content.sha256 is the
#     pre-signature content, so a rebuild with a different key still has to match it;
#     modules.sha256 is the signed canonical artifact set, checked only with --exact.
#
# It does NOT prove a module loads. That is Tier 1 (safe set only) or Tier 2.

set -euo pipefail

RPMDIR="${1:?usage: verify-artifacts.sh <rpm-dir> <kver> <cert.pem> [--record DIR]}"
KVER="${2:?usage: verify-artifacts.sh <rpm-dir> <kver> <cert.pem> [--record DIR]}"
PEM="${3:?usage: verify-artifacts.sh <rpm-dir> <kver> <cert.pem> [--record DIR]}"
shift 3
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
RECORD="$ROOT/akmods-t2/record"
EXACT=0

while (( $# )); do
    case "$1" in
        --record) RECORD="${2:?--record needs a directory}"; shift 2 ;;
        --no-record) RECORD=""; shift ;;
        --exact) EXACT=1; shift ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

fail() { echo "VERIFY FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

[[ -d "$RPMDIR" ]] || fail "no such rpm dir: $RPMDIR"
# Absolute paths: the payload extraction cd's into a temp dir, and rpm2cpio would
# otherwise look for a relative RPM path from there.
RPMDIR="$(cd "$RPMDIR" && pwd)"
[[ -f "$PEM" ]] || fail "no certificate at $PEM"
PEM="$(cd "$(dirname "$PEM")" && pwd)/$(basename "$PEM")"
[[ "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+-.*\.x86_64$ ]] || fail "'$KVER' is not a kernel release"

# The same named set the build packages, in dependency order.
EXPECTED_RPMS=(
    "kmod-t2bce-stack|t2bce_dma t2bce_core t2bce_vhci t2bce_audio t2bce_ave"
    "kmod-t2touchbar|t2hid t2touchbar_bl t2touchbar_kbd"
    "kmod-hid-t2magicmouse|hid_t2magicmouse"
    "kmod-t2bdrm|t2bdrm"
    "kmod-t2smc|t2smc"
    "kmod-t2sbs|t2sbs"
    "kmod-t2mfi-fastcharge|t2mfi_fastcharge"
    "kmod-t2gmux|t2gmux"
    "kmod-t2thunderbolt|t2thunderbolt"
    "kmod-t2smp|t2smp"
    "kmod-t2-precision-trackpad|t2_precision_trackpad"
    "kmod-t2-trackpad-actuator|t2_trackpad_actuator"
)

CN=$(openssl x509 -in "$PEM" -noout -subject -nameopt sep_multiline 2>/dev/null \
        | sed -n 's/^ *CN *= *//p' | head -1)
[[ -n "$CN" ]] || fail "cannot read a CN from $PEM"

# extract-module-sig.pl ships with kernel-devel. Any release's copy reads the same
# appended-signature format, so the host's tree is the right tool even though it is not
# the target kernel. Never substitute a grep on `modinfo` for this.
SIG_EXTRACT="${T2_EXTRACT_SIG:-}"
if [[ -z "$SIG_EXTRACT" ]]; then
    if [[ -x "/usr/src/kernels/$(uname -r)/scripts/extract-module-sig.pl" ]]; then
        SIG_EXTRACT="/usr/src/kernels/$(uname -r)/scripts/extract-module-sig.pl"
    else
        SIG_EXTRACT="$(ls -1 /usr/src/kernels/*/scripts/extract-module-sig.pl 2>/dev/null | head -1)"
    fi
fi
[[ -n "$SIG_EXTRACT" && -x "$SIG_EXTRACT" ]] \
    || fail "extract-module-sig.pl not found; install kernel-devel or set T2_EXTRACT_SIG"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "== 1. the named 12 RPMs, and nothing else =="
mapfile -t rpms < <(find "$RPMDIR" -maxdepth 1 -name '*.rpm' | sort)
(( ${#rpms[@]} == 12 )) || fail "expected 12 RPMs in $RPMDIR, found ${#rpms[@]}: $(printf '%s ' "${rpms[@]##*/}")"
present_names="$(rpm -qp --qf '%{NAME}\n' "${rpms[@]}" | sort)"
expected_names="$(printf '%s\n' "${EXPECTED_RPMS[@]}" | cut -d'|' -f1 | sort)"
if [[ "$present_names" != "$expected_names" ]]; then
    echo "--- present ---" >&2; echo "$present_names" >&2
    echo "--- expected ---" >&2; echo "$expected_names" >&2
    fail "RPM name set does not equal the named 12"
fi
pass "12/12 named RPMs present, no extras"

echo "== 2. every RPM pins exactly $KVER =="
for r in "${rpms[@]}"; do
    grep -qxF "kernel-core-uname-r = $KVER" <(rpm -qpR "$r") \
        || { rpm -qpR "$r" | grep -E 'kernel-(core-)?uname-r' >&2 || true; fail "$(basename "$r") does not require kernel-core-uname-r = $KVER"; }
done
pass "all 12 declare the exact kernel lock"

echo "== 3. package payloads: the named 18 objects, exactly once each =="
extract="$tmp/rpm"
mkdir -p "$extract"
for r in "${rpms[@]}"; do
    ( cd "$extract" && rpm2cpio "$r" | cpio -idm --quiet )
done
mapfile -t kos < <(find "$extract" -name '*.ko' | sort)
(( ${#kos[@]} == 18 )) || fail "expected 18 objects in the RPM payloads, found ${#kos[@]}"
found="$(printf '%s\n' "${kos[@]}" | xargs -d '\n' -n1 basename | sed 's/\.ko$//' | sort)"
want="$(printf '%s\n' "${EXPECTED_RPMS[@]}" | cut -d'|' -f2 | tr ' ' '\n' | sort)"
[[ "$found" == "$want" ]] || {
    echo "--- present ---" >&2; echo "$found" >&2
    echo "--- expected ---" >&2; echo "$want" >&2
    fail "module name set does not equal the named 18"
}
pass "18/18 named objects, no others"

echo "== 4. vermagic, signer and signature, per object =="
bad=0
for ko in "${kos[@]}"; do
    m="$(basename "$ko" .ko)"
    vm="$(modinfo -F vermagic "$ko" 2>/dev/null | awk '{print $1}')"
    [[ "$vm" == "$KVER" ]] || { echo "  FAIL $m: vermagic '$vm' != '$KVER'" >&2; bad=1; }
    signer="$(modinfo -F signer "$ko" 2>/dev/null || true)"
    [[ "$signer" == "$CN" ]] || { echo "  FAIL $m: signer '$signer' != cert CN '$CN'" >&2; bad=1; }
    sig_id="$(modinfo -F sig_id "$ko" 2>/dev/null || true)"
    [[ "$sig_id" == "PKCS#7" ]] || { echo "  FAIL $m: sig_id '$sig_id' != PKCS#7" >&2; bad=1; }

    "$SIG_EXTRACT" -s "$ko" > "$tmp/sig.der" 2>/dev/null || { echo "  FAIL $m: no extractable signature" >&2; bad=1; continue; }
    "$SIG_EXTRACT" -0 "$ko" > "$tmp/content.ko" 2>/dev/null || { echo "  FAIL $m: cannot extract signed content" >&2; bad=1; continue; }
    if ! openssl cms -verify -inform DER -in "$tmp/sig.der" -content "$tmp/content.ko" \
            -binary -certfile "$PEM" -noverify -out /dev/null 2>"$tmp/cms.err"; then
        echo "  FAIL $m: CMS verification failed" >&2; sed 's/^/        /' "$tmp/cms.err" >&2; bad=1
    fi

    # Reproducibility: the pre-signature content is key-independent, so a rebuild with a
    # different throwaway key must still match it. --exact additionally pins the signed
    # bytes to the recorded canonical artifact set (only valid for those exact files).
    if [[ -n "$RECORD" && -f "$RECORD/modules.content.sha256" ]]; then
        want_content="$(awk -v n="$m.content" '{f=$2; sub(/^.*\//,"",f); if (f==n) print $1}' "$RECORD/modules.content.sha256" | head -1)"
        got_content="$(sha256sum "$tmp/content.ko" | cut -d' ' -f1)"
        if [[ -z "$want_content" ]]; then
            echo "  FAIL $m: no content hash in $RECORD/modules.content.sha256" >&2; bad=1
        elif [[ "$got_content" != "$want_content" ]]; then
            echo "  FAIL $m: content sha256 $got_content != recorded $want_content" >&2; bad=1
        fi
    fi
    if (( EXACT )) && [[ -n "$RECORD" && -f "$RECORD/modules.sha256" ]]; then
        recorded="$(awk -v n="$m.ko" '{f=$2; sub(/^.*\//,"",f); if (f==n) print $1}' "$RECORD/modules.sha256" | head -1)"
        got="$(sha256sum "$ko" | cut -d' ' -f1)"
        if [[ -n "$recorded" && "$got" != "$recorded" ]]; then
            echo "  FAIL $m: payload sha256 $got != recorded $recorded" >&2; bad=1
        elif [[ -z "$recorded" ]]; then
            echo "  FAIL $m: no recorded hash in $RECORD/modules.sha256" >&2; bad=1
        fi
    fi
done
(( bad == 0 )) || fail "one or more per-object assertions failed"
pass "18/18 vermagic, signer, PKCS#7 and CMS verified$( [[ -n "$RECORD" && -f "$RECORD/modules.content.sha256" ]] && echo ', content reproducible against the record')$( (( EXACT )) && echo ', signed bytes match the canonical record')"

echo "== 5. negative control — a flipped byte must break the CMS =="
one="${kos[0]}"; one_name="$(basename "$one" .ko)"
"$SIG_EXTRACT" -s "$one" > "$tmp/nc.sig.der" 2>/dev/null
"$SIG_EXTRACT" -0 "$one" > "$tmp/nc.content.ko" 2>/dev/null
cp "$tmp/nc.content.ko" "$tmp/nc.tampered.ko"
perl -e 'open(my $f,"+<",$ARGV[0]) or die $!; binmode $f; seek($f,4096,0); read($f,my $b,1); seek($f,4096,0); print $f chr(ord($b)^0xFF); close $f;' "$tmp/nc.tampered.ko"
if openssl cms -verify -inform DER -in "$tmp/nc.sig.der" -content "$tmp/nc.tampered.ko" \
        -binary -certfile "$PEM" -noverify -out /dev/null 2>/dev/null; then
    fail "tampered content still verified — the CMS check is vacuous"
fi
pass "tampered content rejected (control on $one_name)"

echo "VERIFIED: 12 RPMs / 18 objects for $KVER against $PEM"
echo "Tier 0 only — nothing here loads a module."
