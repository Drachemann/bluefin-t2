#!/bin/bash
# build-all.sh — runs INSIDE the akmods-t2 proof container
# (localhost/bluefin-t2-proof:<kver>, built from ../container/Containerfile).
#
# Builds all 12 t2 kmod specs / 18 objects against the kernel release named on the
# command line, signs every .ko, packages one kmod RPM per spec, and verifies the
# result without ever loading a module.
#
# Usage: build-all.sh <KVER>
#
# The KVER is a required argument on purpose. A default would be a remembered fact and
# would one day build for the wrong kernel; the caller resolves it from the pinned base
# digest's `ostree.linux` label (design R2-13) and passes it in.
#
# Sources are byte-identical copies of research/KaiT2en-Fedora (see ../record/SOURCES.md),
# staged by stage-sources.sh and mounted at /src. Nothing here patches them: a patch that
# seems needed is a finding, not a step.
#
# Exit status = number of specs that failed to build (0 means all 12 built). That is a
# finding count, not a harness error: a failed spec is reported in out/STATUS.md and
# out/MANIFEST.txt does not list an RPM for it.

set -u

KVER="${1:?usage: build-all.sh <KVER>}"
case "$KVER" in
    [0-9]*.[0-9]*.[0-9]*-*.x86_64) ;;
    *) echo "FATAL: KVER '$KVER' is not a kernel release (e.g. 7.2.5-200.fc44.x86_64)" >&2; exit 2 ;;
esac

KD=/usr/src/kernels/$KVER
MODDIR=/lib/modules/$KVER
SRC=/src
OUT=/out
KEYS=/keys
WORK=/work

KEY=${T2_SIGN_KEY:-$KEYS/signing.key}
PEM=${T2_SIGN_CERT:-$KEYS/signing.pem}
# The expected signer is read from the certificate, never hardcoded: the assertion must
# mean "signed by the key whose public half we verify against", and that must hold for a
# rotation key as well as for the throwaway one.
CN=$(openssl x509 -in "$PEM" -noout -subject -nameopt sep_multiline 2>/dev/null \
        | sed -n 's/^ *CN *= *//p' | head -1)
[ -n "$CN" ] || { echo "FATAL: cannot read a CN from $PEM — the signing certificate is unusable" >&2; exit 2; }

RPMDIR=$OUT/rpms
KODIR=$OUT/modules
LOGDIR=$OUT/logs
STATUS=$OUT/STATUS.md
MANIFEST=$OUT/MANIFEST.txt

# spec | rpm name | modules provided (space separated)
SPECS='
t2bce_stack|kmod-t2bce-stack|t2bce_dma t2bce_core t2bce_vhci t2bce_audio t2bce_ave
t2touchbar|kmod-t2touchbar|t2hid t2touchbar_bl t2touchbar_kbd
hid_t2magicmouse|kmod-hid-t2magicmouse|hid_t2magicmouse
t2bdrm|kmod-t2bdrm|t2bdrm
t2smc|kmod-t2smc|t2smc
t2sbs|kmod-t2sbs|t2sbs
t2mfi_fastcharge|kmod-t2mfi-fastcharge|t2mfi_fastcharge
t2gmux|kmod-t2gmux|t2gmux
t2thunderbolt|kmod-t2thunderbolt|t2thunderbolt
t2smp|kmod-t2smp|t2smp
t2_precision_trackpad|kmod-t2-precision-trackpad|t2_precision_trackpad
t2_trackpad_actuator|kmod-t2-trackpad-actuator|t2_trackpad_actuator
'

fail_specs=0
total_ko=0
total_rpms=0

step()  { printf '\n===== %s =====\n' "$*"; }
pass()  { printf 'PASS  %s\n' "$*"; }
bad()   { printf 'FAIL  %s\n' "$*"; }
show()  { printf '$ %s\n' "$*"; }

rm -rf "$RPMDIR" "$KODIR" "$LOGDIR" /work/build
mkdir -p "$RPMDIR" "$KODIR" "$LOGDIR" /work/build

# ------------------------------------------------------------------ environment
step "0. environment"
echo "container kernel (host kernel, shared): $(uname -r)"
echo "target KVER                          : $KVER"
echo "fedora                               : $(cat /etc/fedora-release)"
echo "kernel-devel                         : $KD"
echo "gcc                                  : $(gcc --version | head -1)"
echo "rpm                                  : $(rpm --version)"
echo "openssl                              : $(openssl version)"
echo "sign-file                            : $KD/scripts/sign-file"
echo "signing certificate CN               : $CN"
echo "source tree                          : $SRC"
for f in "$KD/Module.symvers" "$KD/scripts/sign-file" "$KD/scripts/extract-module-sig.pl" "$KEY" "$PEM" /specs/kmod-t2.in; do
    [ -e "$f" ] && pass "present $f" || bad "missing $f"
done
echo "modules in target tree: $(find "$MODDIR" -name '*.ko*' | wc -l)"

# ---------------------------------------------------------------- stage + build
# Implemented function so the same code path runs for every spec.
stage_spec() {
    local spec=$1 dir=/work/build/$1
    mkdir -p "$dir"
    cp -a "$SRC/$spec/." "$dir/"
    if [ "$spec" = t2bce_stack ]; then
        # The DKMS installer stages the stack's components *below* t2bce_stack so
        # Kbuild and modpost share one symbol namespace (see
        # modules/t2bce_stack/README.md and scripts/fedora/install-dkms-modules.sh).
        # AVE lives outside modules/, in t2-services/t2-ave/kernel/t2bce_ave.
        local c
        for c in t2bce_dma t2bce_core t2bce_vhci t2bce_audio; do
            mkdir -p "$dir/$c"
            cp -a "$SRC/components/$c/." "$dir/$c/"
        done
        mkdir -p "$dir/t2bce_ave"
        cp -a "$SRC/t2bce_ave/." "$dir/t2bce_ave/"
    fi
    echo "$dir"
}

build_spec() {
    local spec=$1 dir=$2
    # Exactly what each spec's own `all:` target does:
    #   make -C $(KDIR) M=$(PWD) modules
    # t2bce_stack's Makefile recurses into the staged component dirs itself.
    make -C "$KD" M="$dir" modules > "$LOGDIR/$spec.build.log" 2>&1
    return $?
}

sign_and_verify_ko() {
    # $1 = unsigned .ko path, $2 = module name -> signed .ko in $KODIR
    local unsigned=$1 name=$2 signed=$KODIR/$2.ko rc
    "$KD/scripts/sign-file" sha512 "$KEY" "$PEM" "$unsigned" "$signed"
    rc=$?
    [ $rc -eq 0 ] || { bad "$name: sign-file exit $rc"; return 1; }

    local vm signer keyid hashalgo
    vm=$(modinfo -F vermagic "$signed" 2>/dev/null)
    signer=$(modinfo -F signer "$signed" 2>/dev/null)
    keyid=$(modinfo -F sig_key "$signed" 2>/dev/null)
    hashalgo=$(modinfo -F sig_hashalgo "$signed" 2>/dev/null)

    local okall=0
    if [ "${vm%% *}" = "$KVER" ]; then pass "$name: vermagic ${vm}"; else bad "$name: vermagic '$vm'"; okall=1; fi
    if [ "$signer" = "$CN" ]; then pass "$name: signer CN matches the certificate"; else bad "$name: signer '$signer' != cert CN '$CN'"; okall=1; fi
    if [ -n "$keyid" ]; then pass "$name: sig_key $keyid"; else bad "$name: no sig_key"; okall=1; fi
    if [ "$hashalgo" = sha512 ]; then pass "$name: sig_hashalgo $hashalgo"; else bad "$name: sig_hashalgo '$hashalgo'"; okall=1; fi

    # CMS: the signature covers the module content BEFORE the appended sig block.
    "$KD/scripts/extract-module-sig.pl" -s "$signed" > "/work/$name.sig.der" 2> "/work/$name.extract.err"
    "$KD/scripts/extract-module-sig.pl" -0 "$signed" > "/work/$name.content.ko" 2>> "/work/$name.extract.err"
    if cmp -s "/work/$name.content.ko" "$unsigned"; then
        pass "$name: signed content == unsigned build output"
    else
        bad "$name: extracted signed content differs from the unsigned build"; okall=1
    fi
    if openssl cms -verify -inform DER -in "/work/$name.sig.der" -content "/work/$name.content.ko" \
            -binary -certfile "$PEM" -noverify -out /dev/null 2> "/work/$name.cms.err"; then
        pass "$name: CMS signature verifies against the certificate"
    else
        bad "$name: CMS verification failed"; sed 's/^/      /' "/work/$name.cms.err"; okall=1
    fi
    echo "      signed sha256: $(sha256sum "$signed" | cut -d' ' -f1)"
    return $okall
}

step "1. build, sign and verify all specs"
built_specs=""
# NOTE: read lines with IFS='|' rather than `for line in $SPECS` — the module
# field contains spaces, and word splitting turned each module into a fake spec.
while IFS='|' read -r spec rpmname modules; do
    [ -n "$spec" ] || continue

    step "spec: $spec  (rpm: $rpmname, modules:$modules)"
    dir=$(stage_spec "$spec")

    build_spec "$spec" "$dir"
    rc=$?
    echo "[make exit $rc]"
    tail -12 "$LOGDIR/$spec.build.log" | sed 's/^/    /'

    # Did every expected module appear?
    missing=""
    for m in $modules; do
        find "$dir" -name "$m.ko" | grep -q . || missing="$missing $m"
    done
    if [ $rc -ne 0 ] || [ -n "$missing" ]; then
        bad "$spec did not build (exit $rc; missing:${missing:-none})"
        echo "$spec|FAILED|$rpmname|$modules|$rc" >> /work/spec-status.txt
        fail_specs=$((fail_specs + 1))
        continue
    fi
    pass "$spec built all expected modules:$modules"

    # Sign + verify each .ko of this spec.
    spec_ko=0
    vfail=0
    for m in $modules; do
        unsigned=$(find "$dir" -name "$m.ko" | head -1)
        sign_and_verify_ko "$unsigned" "$m" || vfail=1
        spec_ko=$((spec_ko + 1)); total_ko=$((total_ko + 1))
    done
    if [ $vfail -ne 0 ]; then
        bad "$spec: one or more verification checks failed"
        echo "$spec|BUILT-VERIFY-FAILED|$rpmname|$modules|0" >> /work/spec-status.txt
        fail_specs=$((fail_specs + 1))
        continue
    fi
    built_specs="$built_specs $spec"
    echo "$spec|BUILT|$rpmname|$modules|0" >> /work/spec-status.txt
done <<< "$SPECS"

[ -f /work/spec-status.txt ] || : > /work/spec-status.txt

# Negative control, once: a flipped byte in signed content must be rejected.
step "2. negative control — one flipped byte must break a CMS signature"
CP=$(ls "$KODIR"/*.ko | head -1)
name=$(basename "$CP" .ko)
"$KD/scripts/extract-module-sig.pl" -s "$CP" > /work/nc.sig.der 2>/dev/null
"$KD/scripts/extract-module-sig.pl" -0 "$CP" > /work/nc.content.ko 2>/dev/null
cp /work/nc.content.ko /work/nc.tampered.ko
perl -e 'open(my $f,"+<","/work/nc.tampered.ko") or die $!; binmode $f; seek($f,4096,0); read($f,my $b,1); seek($f,4096,0); print $f chr(ord($b)^0xFF); close $f;'
if openssl cms -verify -inform DER -in /work/nc.sig.der -content /work/nc.tampered.ko -binary \
        -certfile "$PEM" -noverify -out /dev/null 2>/dev/null; then
    bad "tampered content still verified — the CMS check is vacuous"
else
    pass "tampered content rejected (control on $name) — the CMS check is not vacuous"
fi

# --------------------------------------------------------------------- depmod
step "3. depmod against the real $KVER module tree (no loading)"
installed=0
for ko in "$KODIR"/*.ko; do
    install -D -m 0644 "$ko" "$MODDIR/extra/$(basename "$ko")" && installed=$((installed + 1))
done
echo "installed $installed signed modules into $MODDIR/extra/"
DEPOUT=$(depmod -a "$KVER" 2>&1); rc=$?
echo "$DEPOUT"
echo "[depmod exit $rc]"
if [ $rc -eq 0 ] && [ -z "$DEPOUT" ]; then
    pass "depmod exit 0 with no warnings and no unresolved symbols"
else
    bad "depmod reported problems (exit $rc)"
fi
missdep=0
for ko in "$KODIR"/*.ko; do
    n=$(basename "$ko" .ko)
    grep -q "extra/$n.ko:" "$MODDIR/modules.dep" || { bad "$n absent from modules.dep"; missdep=1; }
done
[ $missdep -eq 0 ] && pass "every module is present in modules.dep"
show "modprobe --show-depends for t2bce_stack members (resolves, does not load)"
for n in t2bce_dma t2bce_core t2bce_vhci t2bce_audio t2bce_ave; do
    [ -f "$KODIR/$n.ko" ] && modprobe --show-depends -S "$KVER" "$n" 2>&1 | sed 's/^/    /'
done
[ -f "$KODIR/t2hid.ko" ] && modprobe --show-depends -S "$KVER" t2hid 2>&1 | sed 's/^/    /'

# ------------------------------------------------------------------ package RPM
step "4. one proof kmod RPM per built spec"
: > "$MANIFEST"
{
    echo "# bluefin-t2 A1 kmod manifest"
    echo "# kver: $KVER"
    echo "# built: $(date -u '+%Y-%m-%dT%H:%M:%SZ') in bluefin-t2-proof:$KVER"
    echo "# signature: $CN"
    echo "# columns: rpm_file<TAB>sha256<TAB>modules<TAB>kver"
} >> "$MANIFEST"

mkdir -p /root/rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

while IFS='|' read -r spec rpmname modules; do
    [ -n "$spec" ] || continue
    grep -q "^$spec|BUILT|" /work/spec-status.txt || continue

    ver=$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)".*/\1/p' "/work/build/$spec/dkms.conf" 2>/dev/null)
    [ -n "$ver" ] || ver=0.1

    rm -f /root/rpmbuild/SOURCES/*.ko
    files=""
    for m in $modules; do
        cp "$KODIR/$m.ko" /root/rpmbuild/SOURCES/"$m.ko"
        files="$files/usr/lib/modules/$KVER/extra/$m.ko
"
    done

    # The spec is a file (specs/kmod-t2.in, mounted at /specs), not a heredoc: the
    # packaging contract is reviewable without reading this script, and the contributor
    # loop's rpmbuild path and this proof build share one template (design §5 call 3).
    sed -e "s|@NAME@|$rpmname|g" \
        -e "s|@VERSION@|$ver|g" \
        -e "s|@KVER@|$KVER|g" \
        -e "s|@MODULES@|$modules|g" \
        -e '/@FILES@/d' /specs/kmod-t2.in > /root/rpmbuild/SPECS/"$rpmname".spec
    printf '%s' "$files" >> /root/rpmbuild/SPECS/"$rpmname".spec

    rpmbuild -bb /root/rpmbuild/SPECS/"$rpmname".spec > "$LOGDIR/$rpmname.rpmbuild.log" 2>&1
    rc=$?
    rpmfile=$(ls /root/rpmbuild/RPMS/x86_64/"$rpmname"-*.rpm 2>/dev/null | head -1)
    if [ $rc -ne 0 ] || [ -z "$rpmfile" ]; then
        bad "$rpmname: rpmbuild failed (exit $rc)"; tail -8 "$LOGDIR/$rpmname.rpmbuild.log" | sed 's/^/    /'
        echo "$spec|BUILT-RPM-FAILED|$rpmname|$modules|$rc" >> /work/spec-status.txt
        continue
    fi
    cp "$rpmfile" "$RPMDIR/"
    total_rpms=$((total_rpms + 1))

    show "rpm -qpR $(basename "$rpmfile") | grep kernel-core-uname-r"
    reqline=$(rpm -qpR "$rpmfile" 2>/dev/null | grep kernel-core-uname-r)
    echo "$reqline"
    if [ "$reqline" = "kernel-core-uname-r = $KVER" ]; then
        pass "$rpmname declares kernel-core-uname-r = $KVER"
    else
        bad "$rpmname requires line unexpected: '$reqline'"
    fi

    # Re-verify every .ko from inside the packaged RPM: packaging must not damage
    # the signature, and the vermagic/signer must survive.
    rm -rf /work/rpmcheck && mkdir -p /work/rpmcheck && ( cd /work/rpmcheck && rpm2cpio "$rpmfile" | cpio -id --quiet )
    pkgfail=0
    for m in $modules; do
        pko=/work/rpmcheck/usr/lib/modules/$KVER/extra/$m.ko
        if [ ! -f "$pko" ]; then bad "$rpmname: $m.ko missing from RPM payload"; pkgfail=1; continue; fi
        [ "$(modinfo -F vermagic "$pko" | cut -d' ' -f1)" = "$KVER" ] || { bad "$rpmname/$m: vermagic wrong in payload"; pkgfail=1; }
        [ "$(modinfo -F signer "$pko")" = "$CN" ] || { bad "$rpmname/$m: signer wrong in payload"; pkgfail=1; }
        "$KD/scripts/extract-module-sig.pl" -s "$pko" > /work/p.sig.der 2>/dev/null
        "$KD/scripts/extract-module-sig.pl" -0 "$pko" > /work/p.content.ko 2>/dev/null
        openssl cms -verify -inform DER -in /work/p.sig.der -content /work/p.content.ko \
            -binary -certfile "$PEM" -noverify -out /dev/null 2>/dev/null \
            || { bad "$rpmname/$m: CMS fails after packaging"; pkgfail=1; }
    done
    [ $pkgfail -eq 0 ] && pass "$rpmname: all packaged modules verify (vermagic, signer, CMS)"

    sha=$(sha256sum "$RPMDIR/$(basename "$rpmfile")" | cut -d' ' -f1)
    printf '%s\t%s\t%s\t%s\n' "$(basename "$rpmfile")" "$sha" "$(echo $modules | tr ' ' ',')" "$KVER" >> "$MANIFEST"
done <<< "$SPECS"

# ------------------------------------------------------------------- status.md
step "5. status"
{
    echo "# A1 kmod build status — $KVER"
    echo
    echo "| spec | status | rpm | modules |"
    echo "| --- | --- | --- | --- |"
    while IFS='|' read -r spec st rpmname modules rc; do
        echo "| \`$spec\` | $st | \`$rpmname\` | $modules |"
    done < /work/spec-status.txt
    echo
    echo "- specs attempted: $(printf '%s\n' "$SPECS" | grep -c .)"
    echo "- specs built: $(grep -c '|BUILT|' /work/spec-status.txt)"
    echo "- modules signed: $total_ko"
    echo "- rpms produced: $total_rpms"
    echo "- kmod tree: $MODDIR/extra/"
} > "$STATUS"
cat "$STATUS"

echo
echo "=== MANIFEST.txt ==="
cat "$MANIFEST"

step "6. artifacts"
sha256sum "$KODIR"/*.ko > "$OUT/modules.sha256"
ls -la "$RPMDIR" "$KODIR"
echo "--- modules.sha256 ---"
cat "$OUT/modules.sha256"

echo
echo "RESULT: $((12 - fail_specs))/12 specs built, $total_ko/18 modules signed, $total_rpms/12 RPMs"
if [ $fail_specs -eq 0 ] && [ $total_ko -eq 18 ] && [ $total_rpms -eq 12 ]; then
    echo "ALL EXPECTED ARTIFACTS PRESENT"
else
    echo "INCOMPLETE — see STATUS.md and logs/"
fi
exit $fail_specs
