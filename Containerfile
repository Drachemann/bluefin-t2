# bluefin-t2 — Artifact 2, **bench slice**
#
# A thin derivative of Bluefin Classic: FROM the pinned digest, then our own steps.
# This slice answers one question at Tier 2 — does the image boot on a T2 Mac with our
# kernel modules bound? It also carries the first slice of the release surface: the
# `bluefin-t2 report` binary built in the builder stage and installed at step 03, because
# the Tier 2 smoke test and the hub both consume its JSON. The remaining userspace (the
# eight inherited apps, t2remote, the hub, SELinux, PAM) is not here yet; see
# `docs/runbooks/tier2-bench.md` §2 for what that costs.
#
# Ordering is the design's (§5): kmods -> support files -> userspace -> initramfs -> gates
# -> lint. `bootc container lint` is last, as Bluefin runs it, and it is never disabled.
#
# Build through `./build.sh`, which resolves the digest and the KVER and stages the
# context. A bare `podman build .` will fail on the ARG checks, on purpose.

ARG BASE_IMAGE=ghcr.io/ublue-os/bluefin
ARG BASE_DIGEST
ARG KVER

# --- builder stage (design §5 B1–B4): compiles only, never reaches the image ----------
# Same pinned base as the image, so GTK/glib versions match the runtime exactly. Nothing
# from this stage survives except /out.
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS t2build

# B1 — the build-only set. These packages are in the builder, never in the final image;
# 90-tests.sh asserts the final image has no kernel-devel and no /usr/src tree.
RUN dnf5 install -y \
        --setopt=install_weak_deps=False \
        --setopt=tsflags=nodocs \
        cargo rust gtk4-devel libadwaita-devel libinput-devel libplist-devel \
        systemd-devel glib2-devel rpm-build pkgconf-pkg-config gcc make python3 \
        checkpolicy policycoreutils selinux-policy-devel \
 && dnf5 clean all

# B2 — the pinned KAIT2EN sources and our own userspace tree.
COPY kait2en/ /src/kait2en/
COPY apps/ /src/apps/
COPY specs/ /src/specs/
COPY build_files/build-userspace.sh /usr/libexec/bluefin-t2/build-userspace.sh

# B3 — build and package into /out/rpms. B4 (the SELinux module) attaches here once the
# policy exists; /out/selinux is reserved for it.
RUN /usr/libexec/bluefin-t2/build-userspace.sh /out

FROM ${BASE_IMAGE}@${BASE_DIGEST}

# 1 for a release image (no Tier 2 harness), 0 for the bench slice. build.sh --release
# strips the marked harness block and passes 1; the gates assert the right shape either way.
ARG RELEASE=0
ARG KVER

LABEL org.opencontainers.image.title="bluefin-t2 bench slice" \
      org.opencontainers.image.description="Tier 2 boot-path slice: T2 kernel modules, kargs, initramfs" \
      org.bluefin-t2.slice="bench-t2" \
      ostree.linux="${KVER}"

# --- step 01: the kernel modules, and the lock that ties them to this kernel ----------
# Refuses to build if any RPM does not require exactly $KVER. That assertion lives in
# the script, not here, so it is one guard for every caller.
COPY rpms/ /tmp/t2-kmods/
COPY build_files/01-install-kmods.sh /usr/libexec/bluefin-t2/01-install-kmods.sh
RUN /usr/libexec/bluefin-t2/01-install-kmods.sh "${KVER}" /tmp/t2-kmods \
 && rm -rf /tmp/t2-kmods

# dnf leaves runtime-only residue that `bootc container lint` (correctly) flags:
# /run/dnf, a dnf log, and the libdnf5 cache. None of it belongs in an image.
RUN rm -rf /run/dnf /var/log/dnf5.log /var/cache/libdnf5 /var/lib/dnf/repos \
 && rm -f /var/cache/ldconfig/aux-cache

# --- step 02: our own files: kargs, dracut force_drivers, modules-load, models.d ------
COPY system_files/ /

# The image must not depend on first boot to create the Touch Bar device group: a
# per-user helper may add the caller to an existing group but must never define a system
# group, so materialise /usr/lib/sysusers.d here. Verified by 90-tests.sh (gate 11).
RUN systemd-sysusers

# --- step 03: the userspace RPMs built in the builder stage ---------------------------
# One RPM per binary; dnf5 refuses an uninstalled dependency, and the package is the only
# thing that crosses the stage boundary.
COPY --from=t2build /out/rpms/ /tmp/t2-userspace-rpms/
RUN dnf5 install -y --setopt=install_weak_deps=False --setopt=tsflags=nodocs \
        /tmp/t2-userspace-rpms/*.rpm \
 && rm -rf /tmp/t2-userspace-rpms /run/dnf /var/log/dnf5.log /var/cache/libdnf5 /var/lib/dnf/repos \
 && rm -f /var/cache/ldconfig/aux-cache

# --- step 04: SELinux policy at priority 400, and the PAM fingerprint stack -----------
# The policy module is compiled in the builder (B4). Priority 400 keeps it ahead of the
# distribution's 100-level modules without replacing any of them. `authselect` selects
# the local profile's with-fingerprint feature; 90-tests.sh asserts the resulting stack.
# Its /var/lib/authselect checksum is boot-time state, not image content — `authselect
# check` recomputes it and stays valid without it — so it is removed in the same layer.
COPY --from=t2build /out/selinux/ /tmp/t2-selinux/
RUN semodule -X 400 -i /tmp/t2-selinux/*.pp \
 && rm -rf /tmp/t2-selinux \
 && authselect enable-feature with-fingerprint \
 && rm -rf /var/lib/authselect

# --- step 04b: the public signing certificate ----------------------------------------
# Public material only. mokutil --import needs a DER in the filesystem, and the report uses
# its presence to distinguish on-not-enrolled from on-unknown when Secure Boot is on. The
# checksum is what gate 17 compares, so the shipped DER is provably the build's signer.
COPY certs/bluefin-t2.der /etc/pki/akmods/certs/bluefin-t2.der
COPY certs/bluefin-t2.der.sha256 /usr/share/bluefin-t2/certs/bluefin-t2.der.sha256
RUN chmod 0644 /etc/pki/akmods/certs/bluefin-t2.der /usr/share/bluefin-t2/certs/bluefin-t2.der.sha256

# --- step 05: caches, after every file is in place ------------------------------------
# gtk-update-icon-cache writes /usr/share/icons/hicolor/icon-theme.cache, which is image
# content. No fonts are added by this image, so fc-cache is not needed; no dconf profiles
# are shipped, so dconf update is not needed either.
RUN gtk-update-icon-cache --force --ignore-theme-index /usr/share/icons/hicolor

# >>> bench-only-harness
# --- the Tier 2 harness layer (BENCH SLICE ONLY) ------------------------------------
# Stage loggers, the smoke test and three harness units. The release image keeps these
# out — they are harness surface, not product surface — but a bench image without them
# writes no stage lines and no result.json, and the run correctly reports
# FAILED_BOOT/HARNESS_ERROR. This is the one difference between this slice and the
# release image that the record has to name (docs/runbooks/tier2-bench.md §2).
COPY rootfs/ /
# <<< bench-only-harness

# --- step 06: the initramfs, with the six early-boot objects inside it ---------------
COPY build_files/19-initramfs.sh /usr/libexec/bluefin-t2/19-initramfs.sh
RUN /usr/libexec/bluefin-t2/19-initramfs.sh "${KVER}"

# --- step 07: our gates. lsinitrd is the only proof of the initramfs guarantee ------
# The three build-step scripts are removed once the gates pass: they are build-time
# harness, not image content, and leaving them would be exactly the residue gate 8 and the
# gate-14 policy assertion exist to prevent.
COPY build_files/90-tests.sh /usr/libexec/bluefin-t2/90-tests.sh
RUN RELEASE="${RELEASE}" /usr/libexec/bluefin-t2/90-tests.sh "${KVER}" \
 && rm -f /usr/libexec/bluefin-t2/01-install-kmods.sh \
          /usr/libexec/bluefin-t2/19-initramfs.sh \
          /usr/libexec/bluefin-t2/90-tests.sh

# --- step 08: bootc's own lint, last, never skipped ---------------------------------
RUN bootc container lint

CMD ["/sbin/init"]
