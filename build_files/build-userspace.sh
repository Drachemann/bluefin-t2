#!/bin/bash
# build-userspace.sh — runs INSIDE the A2 builder stage (design §5 B2–B3).
#
# Builds bluefin-t2's own binary and the eight inherited apps plus t2remote, stages each
# one into a package tree, and packages one RPM per app into /out/rpms. Nothing except
# /out crosses into the final image.
#
# Two deliberate departures from the upstream installers, both recorded in
# research/findings/userspace-layer.md:
#
#   * Paths. Upstream installs under /usr/local; this image owns /usr. Unit files are
#     rendered with /usr/bin and /usr/libexec, exactly as t2remote's own unit already
#     does with @BINDIR@.
#   * Ordering. The app daemons carry `After=multi-user.target` while being
#     `WantedBy=multi-user.target` — a unit ordered after the target that wants it is an
#     ordering cycle, and systemd breaks such a cycle by deleting a job. The line is
#     dropped when the unit is staged; the daemons keep their default multi-user start.
#
# `make install` is not used: upstream's install targets call systemctl and write as root,
# neither of which is meaningful in a builder. Copying the same files explicitly is also
# what keeps each package's file list reviewable.

set -euo pipefail

SRC=${SRC:-/src}
OUT=${1:-/out}
RPMDIR=$OUT/rpms
MANIFEST=$OUT/MANIFEST.txt
SPEC_TEMPLATE=$SRC/specs/app-tree.spec.in
KAIT2EN=$SRC/kait2en
BUILD=/work/pkg
# One target dir for every crate: the GTK stack is the same for all of them, so this is
# the difference between compiling gtk4 once and compiling it six times.
export CARGO_TARGET_DIR=/work/target
TARGET=$CARGO_TARGET_DIR

step() { printf '\n===== %s =====\n' "$*"; }
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; exit 1; }

[[ -f "$SPEC_TEMPLATE" ]] || fail "missing spec template $SPEC_TEMPLATE"
[[ -d "$KAIT2EN/apps" ]] || fail "missing pinned sources at $KAIT2EN"

mkdir -p "$RPMDIR" "$BUILD" /root/rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
: > "$MANIFEST"
echo "# bluefin-t2 userspace manifest — rpm<TAB>sha256" >> "$MANIFEST"

cargo_build() {
    local dir=$1
    shift
    ( cd "$dir" && cargo build --release --locked "$@" )
}

version_of() {
    sed -n 's/^version = "\(.*\)"/\1/p' "$1/Cargo.toml" | head -1
}

pkgroot() {
    local root=$BUILD/$1
    rm -rf "$root"
    mkdir -p "$root"
    echo "$root"
}

put() {
    local root=$1 src=$2 dst=$3 mode=${4:-0644}
    [[ -e "$src" ]] || fail "missing source $src"
    install -D -m "$mode" "$src" "$root/$dst"
}

# Units: render /usr paths, and drop the self-ordering line (see the header).
put_unit() {
    local root=$1 src=$2 dst=$3
    [[ -f "$src" ]] || fail "missing unit $src"
    mkdir -p "$(dirname "$root/$dst")"
    sed -e 's|@BINDIR@|/usr/bin|g' \
        -e 's|/usr/local/bin|/usr/bin|g' \
        -e 's|/usr/local/libexec|/usr/libexec|g' \
        -e '/^After=multi-user.target$/d' \
        "$src" > "$root/$dst"
    chmod 0644 "$root/$dst"
}

# Desktop entries: upstream hardcodes /usr/local/bin in Exec=; this image owns /usr.
put_desktop() {
    local root=$1 src=$2 dst=$3
    [[ -f "$src" ]] || fail "missing desktop entry $src"
    mkdir -p "$(dirname "$root/$dst")"
    sed -e 's|/usr/local/bin|/usr/bin|g' "$src" > "$root/$dst"
    chmod 0644 "$root/$dst"
}

package_tree() {
    local name=$1 version=$2 summary=$3 license=$4 description=$5 root=$6 requires=${7:-}
    local spec=/root/rpmbuild/SPECS/"$name".spec
    [[ -n "$version" ]] || version=0.1.0
    sed -e "s|@NAME@|$name|g" \
        -e "s|@VERSION@|$version|g" \
        -e "s|@SUMMARY@|$summary|g" \
        -e "s|@LICENSE@|$license|g" \
        -e "s|@DESCRIPTION@|$description|g" \
        -e "s|@PKGROOT@|$root|g" \
        -e "s|@REQUIRES@|$requires|g" \
        -e '/@FILES@/d' \
        "$SPEC_TEMPLATE" > "$spec"
    ( cd "$root" && find . -mindepth 1 \( -type f -o -type l \) -printf '%P\n' | sort ) |
        while IFS= read -r p; do
            case "$p" in
                etc/*) printf '%%config(noreplace) /%s\n' "$p" ;;
                *)     printf '/%s\n' "$p" ;;
            esac
        done >> "$spec"

    rpmbuild -bb "$spec" > "/tmp/$name.rpmbuild.log" 2>&1 || {
        tail -20 "/tmp/$name.rpmbuild.log" >&2
        fail "$name: rpmbuild failed"
    }
    local rpmfile
    rpmfile="$(ls /root/rpmbuild/RPMS/x86_64/"$name"-*.rpm 2>/dev/null | head -1)"
    [[ -n "$rpmfile" ]] || fail "$name: no RPM produced"
    cp "$rpmfile" "$RPMDIR/"
    printf '%s\t%s\n' "$(basename "$rpmfile")" "$(sha256sum "$rpmfile" | cut -d' ' -f1)" >> "$MANIFEST"
    pass "$name $version -> $(basename "$rpmfile") ($(find "$root" -type f | wc -l) files)"
}

# ---------------------------------------------------------------- bluefin-t2 (report)
step "app: bluefin-t2 (report and hub)"
# One binary: `report` is the machine's verdict, no-arguments is the hub that renders it.
# The hub links GTK, so this crate needs the registry; --locked pins the resolution. The
# report path never initialises GTK, so it still runs in a headless rescue session.
cargo_build "$SRC/apps/bluefin-t2"
root=$(pkgroot bluefin-t2)
put "$root" "$TARGET/release/bluefin-t2" usr/bin/bluefin-t2 0755
put_desktop "$root" "$SRC/apps/bluefin-t2/org.bluefin_t2.Hub.desktop" \
    usr/share/applications/org.bluefin_t2.Hub.desktop
package_tree bluefin-t2 "$(version_of "$SRC/apps/bluefin-t2")" \
    "bluefin-t2 report — what works on this machine, from the model's expectation set" \
    GPL-3.0-or-later \
    "Reports what works on this machine from /usr/share/bluefin-t2/models.d; exit codes 0 (ok), 1 (not ok), 2 (unsupported model). --json is the contract shared with the hub and the Tier 2 smoke test." \
    "$root"

# ---------------------------------------------------------------- t2-touchbar
step "app: t2-touchbar"
cargo_build "$KAIT2EN/apps/t2-touchbar"
root=$(pkgroot t2-touchbar)
put "$root" "$TARGET/release/kait2en-touchbar" usr/bin/kait2en-touchbar 0755
put_unit "$root" "$KAIT2EN/apps/t2-touchbar/integration/systemd/user/kait2en-touchbar.service" \
    usr/lib/systemd/user/kait2en-touchbar.service
put_unit "$root" "$KAIT2EN/apps/t2-touchbar/integration/systemd/system/kait2en-touchbar-attach.service" \
    usr/lib/systemd/system/kait2en-touchbar-attach.service
put "$root" "$KAIT2EN/apps/t2-touchbar/integration/udev/99-zz-kait2en-touchbar.rules" \
    usr/lib/udev/rules.d/99-zz-kait2en-touchbar.rules
put "$root" "$KAIT2EN/apps/t2-touchbar/THIRD-PARTY-NOTICES.md" \
    usr/share/licenses/kait2en-touchbar/THIRD-PARTY-NOTICES.md
put "$root" "$KAIT2EN/apps/t2-touchbar/config/touchbar.toml" etc/kait2en/touchbar.toml
package_tree t2-touchbar "$(version_of "$KAIT2EN/apps/t2-touchbar")" \
    "Apple T2 Touch Bar daemon and attach unit" GPL-3.0-or-later \
    "The Touch Bar daemon, its system attach unit, its udev rule and its default config." \
    "$root"

# ---------------------------------------------------------------- the GTK apps
# name | source dir | binary | desktop id | unit file (empty = none)
GTK_APPS='
t2-fan-control|apps/t2-fan-control|t2-fancontrol-gtk|org.t2fancontrol.gtk|t2-fancontrol.service
t2-smc-control|apps/t2-smc-control|t2-smc-control|org.t2smccontrol.gtk|t2-smc-gaugingd.service
t2-zone-power|apps/t2-zone-power|t2-zonepower-gtk|org.t2zonepower.gtk|t2-zonepowerd.service
t2-force-click|apps/t2-force-click|t2-force-click|org.t2forceclick.gtk|t2-force-click.service
t2-debug|apps/t2-debug|t2-debug|org.t2debug.gtk|
'
while IFS='|' read -r name dir bin desktop unit; do
    [[ -n "$name" ]] || continue
    step "app: $name"
    cargo_build "$KAIT2EN/$dir"
    root=$(pkgroot "$name")
    put "$root" "$TARGET/release/$bin" "usr/bin/$bin" 0755
    # t2-debug also ships its CLI binary.
    if [[ "$name" == t2-debug && -x "$TARGET/release/t2debug" ]]; then
        put "$root" "$TARGET/release/t2debug" usr/bin/t2debug 0755
    fi
    put_desktop "$root" "$KAIT2EN/$dir/$desktop.desktop" "usr/share/applications/$desktop.desktop"
    put "$root" "$KAIT2EN/$dir/assets/icons/hicolor/scalable/apps/$desktop.svg" \
        "usr/share/icons/hicolor/scalable/apps/$desktop.svg"
    if [[ -n "$unit" ]]; then
        put_unit "$root" "$KAIT2EN/$dir/systemd/$unit" "usr/lib/systemd/system/$unit"
    fi
    package_tree "$name" "$(version_of "$KAIT2EN/$dir")" "$desktop application for T2 hardware" \
        GPL-3.0-or-later "The $desktop GTK application and, where present, its daemon unit." "$root"
done <<< "$GTK_APPS"

# ---------------------------------------------------------------- t2-power-explorer
step "app: t2-power-explorer"
cargo_build "$KAIT2EN/apps/t2-power-explorer"
root=$(pkgroot t2-power-explorer)
put "$root" "$TARGET/release/t2-power-explorer" usr/bin/t2-power-explorer 0755
put "$root" "$KAIT2EN/apps/t2-power-explorer/t2-power-explorer-status" \
    usr/libexec/t2-power-explorer-status 0755
put "$root" "$KAIT2EN/apps/t2-power-explorer/org.t2powerexplorer.policy" \
    usr/share/polkit-1/actions/org.t2powerexplorer.policy
put_desktop "$root" "$KAIT2EN/apps/t2-power-explorer/org.t2powerexplorer.gtk.desktop" \
    usr/share/applications/org.t2powerexplorer.gtk.desktop
put "$root" "$KAIT2EN/apps/t2-power-explorer/assets/icons/hicolor/scalable/apps/org.t2powerexplorer.gtk.svg" \
    usr/share/icons/hicolor/scalable/apps/org.t2powerexplorer.gtk.svg
package_tree t2-power-explorer "$(version_of "$KAIT2EN/apps/t2-power-explorer")" \
    "Power-state explorer GTK application" GPL-3.0-or-later \
    "Reads and explains the machine's power state; ships its privileged status helper and polkit action." \
    "$root"

# ---------------------------------------------------------------- t2-power-tune (Python)
step "app: t2-power-tune"
root=$(pkgroot t2-power-tune)
put "$root" "$KAIT2EN/apps/t2-power-tune/t2-power-tune.py" usr/bin/t2-power-tune 0755
put "$root" "$KAIT2EN/apps/t2-power-tune/t2-power-tune-helper" usr/libexec/t2-power-tune-helper 0755
put "$root" "$KAIT2EN/apps/t2-power-tune/t2-power-tune-status" usr/libexec/t2-power-tune-status 0755
put "$root" "$KAIT2EN/apps/t2-power-tune/org.t2powertune.policy" \
    usr/share/polkit-1/actions/org.t2powertune.policy
put_desktop "$root" "$KAIT2EN/apps/t2-power-tune/org.t2powertune.gtk.desktop" \
    usr/share/applications/org.t2powertune.gtk.desktop
put "$root" "$KAIT2EN/apps/t2-power-tune/org.t2powertune.gtk.svg" \
    usr/share/icons/hicolor/scalable/apps/org.t2powertune.gtk.svg
package_tree t2-power-tune 0.1.0 "Power-limit tuning application (Python/GTK)" GPL-3.0-or-later \
    "Sets and explains the machine's power limits through a privileged helper and polkit action." \
    "$root" "Requires: python3-gobject"

# ---------------------------------------------------------------- t2remote
step "app: t2remote"
cargo_build "$KAIT2EN/t2-services/t2-ave"
root=$(pkgroot t2remote)
put "$root" "$TARGET/release/t2remote" usr/bin/t2remote 0755
put_unit "$root" "$KAIT2EN/t2-services/t2-ave/integration/systemd/kait2en-t2-remote.service" \
    usr/lib/systemd/system/kait2en-t2-remote.service
put "$root" "$KAIT2EN/t2-services/t2-ave/integration/systemd/t2-ave-suspend" \
    usr/libexec/t2-services/sleep.d/t2-ave 0755
package_tree t2remote "$(version_of "$KAIT2EN/t2-services/t2-ave")" \
    "T2 AVE service daemon (t2remote) and its suspend helper" GPL-3.0-or-later \
    "The t2remote daemon, its systemd unit and the suspend helper the shared T2 services call." \
    "$root"

# ---------------------------------------------------------------- t2-dsp
# Host-side PipeWire/WirePlumber graphs, FIR assets and udev model selection. No Apple
# firmware and no T2 service dependency; GPL like the rest. The RPM's Requires pull the
# LV2 plugins the graphs use into the final image at step 03.
step "app: t2-dsp"
( cd "$KAIT2EN/dsp" && make build ) || fail "t2-dsp: make build failed"
root=$(pkgroot t2-dsp)
( cd "$KAIT2EN/dsp" && make install PREFIX=/usr DESTDIR="$root" ) || fail "t2-dsp: make install failed"
package_tree t2-dsp 0.1.0 "Model-specific host-side audio DSP for Apple T2 Macs" GPL-3.0-or-later \
    "PipeWire filter-chain graphs and FIR assets for the internal speakers and microphone, with udev/WirePlumber model selection." \
    "$root" "Requires: pipewire\nRequires: wireplumber\nRequires: pipewire-module-filter-chain-lv2\nRequires: lv2-bankstown\nRequires: lsp-plugins-lv2\nRequires: systemd-udev"

# ---------------------------------------------------------------- t2-touchid
# The Touch ID bridge: the Secure Enclave keeps the fingerprint, this daemon feeds fprintd
# through libfprint's virtual device, and user-groups binds the macOS-enrolled fingers to
# the Linux account. Without this package, `fprintd-enroll` answers "No devices available".
step "app: t2-touchid"
( cd "$KAIT2EN/t2-services/t2-touchid" && cargo build --release --locked ) \
    || fail "t2-touchid: cargo build failed"
root=$(pkgroot t2-touchid)
put "$root" "$TARGET/release/t2-touchid" usr/bin/t2-touchid 0755
put_unit "$root" "$KAIT2EN/t2-services/t2-touchid/integration/systemd/kait2en-t2-touchid.service" \
    usr/lib/systemd/system/kait2en-t2-touchid.service
put "$root" "$KAIT2EN/t2-services/t2-touchid/integration/fprintd/fprintd-kait2en-t2-touchid.conf" \
    usr/lib/systemd/system/fprintd.service.d/kait2en-t2-touchid.conf
put "$root" "$KAIT2EN/t2-services/t2-touchid/integration/dbus/org.kait2en.TouchId.conf" \
    usr/share/dbus-1/system.d/org.kait2en.TouchId.conf
put "$root" "$KAIT2EN/t2-services/t2-touchid/config/t2-touchid.conf" etc/kait2en/t2-touchid.conf
package_tree t2-touchid 0.1.0 "Apple T2 Touch ID bridge for fprintd" GPL-3.0-or-later \
    "Bridges the T2 Secure Enclave to stock fprintd through libfprint's virtual device, so login and sudo accept the finger enrolled under macOS." \
    "$root" "Requires: fprintd"

# ---------------------------------------------------------------- B4: SELinux module
# The only policy source in the pinned tree is the Touch ID bridge's: fprintd creates a
# runtime socket directory and needs a type for it. It is compiled here (the builder has
# checkpolicy) and installed at priority 400 by the image's step 04.
step "selinux: kait2en-t2-touchid"
SELINUX_SRC=$KAIT2EN/t2-services/t2-touchid/integration/selinux
[[ -f "$SELINUX_SRC/kait2en-t2-touchid.te" ]] || fail "missing SELinux source at $SELINUX_SRC"
mkdir -p "$OUT/selinux"
checkmodule -M -m -o /tmp/kait2en-t2-touchid.mod "$SELINUX_SRC/kait2en-t2-touchid.te"
semodule_package -o "$OUT/selinux/kait2en-t2-touchid.pp" \
    -m /tmp/kait2en-t2-touchid.mod -f "$SELINUX_SRC/kait2en-t2-touchid.fc"
rm -f /tmp/kait2en-t2-touchid.mod
pass "kait2en-t2-touchid.pp built ($(stat -c %s "$OUT/selinux/kait2en-t2-touchid.pp") bytes)"

# ---------------------------------------------------------------- result
step "result"
ls -l "$RPMDIR"
count="$(find "$RPMDIR" -maxdepth 1 -name '*.rpm' | wc -l)"
echo "RESULT: $count userspace RPM(s)"
[[ "$count" -eq 12 ]] || fail "expected 12 userspace RPMs (8 apps + t2remote + report + t2-dsp + t2-touchid), built $count"
echo "ALL USERSPACE PACKAGES PRESENT"
