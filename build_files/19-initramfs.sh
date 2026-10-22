#!/usr/bin/bash
# Rebuild the initramfs for one kernel release, as Bluefin does it.
# Mirrors research/bluefin/build_files/base/19-initramfs.sh:7-9 — same flags, same
# destination — with the kernel passed in rather than discovered by rpm, because this
# image has exactly one kernel and the caller already resolved it from the digest label.

set -euo pipefail

KVER="${1:?usage: 19-initramfs.sh <KVER>}"

test -d "/usr/src/kernels/${KVER}" && {
    # kernel-devel must NOT be in the image (Bluefin removes it). If it is here, the
    # build environment leaked in and the image is wrong.
    echo "FATAL: kernel-devel tree present at /usr/src/kernels/${KVER} — build-only set leaked into the image" >&2
    exit 1
}

test -f "/lib/modules/${KVER}/modules.dep" \
    || { echo "FATAL: /lib/modules/${KVER}/modules.dep missing — depmod did not run" >&2; exit 1; }

export DRACUT_NO_XATTR=1
/usr/bin/dracut --no-hostonly \
    --kver "${KVER}" \
    --reproducible \
    --add ostree \
    -f "/lib/modules/${KVER}/initramfs.img"
chmod 0600 "/lib/modules/${KVER}/initramfs.img"
