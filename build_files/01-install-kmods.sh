#!/usr/bin/bash
# Install the T2 kmod RPMs for exactly one kernel release.
#
# Usage: 01-install-kmods.sh <KVER> <rpm-dir>
#
# The guard is the point: every RPM must declare `Requires: kernel-core-uname-r = <KVER>`
# before anything is installed. That dependency is what makes kernel/module lockstep a
# property rather than a remembered rule — if the tag check upstream were ever deleted,
# this still refuses a mismatched module. Do not relax it to make a build pass.

set -euo pipefail

KVER="${1:?usage: 01-install-kmods.sh <KVER> <rpm-dir>}"
RPMDIR="${2:?usage: 01-install-kmods.sh <KVER> <rpm-dir>}"

shopt -s nullglob
rpms=("$RPMDIR"/*.rpm)
if (( ${#rpms[@]} == 0 )); then
    echo "FATAL: no kmod RPMs in $RPMDIR — the kmod build produced nothing for $KVER" >&2
    exit 1
fi

# Every RPM must pin this kernel. A kmod without the requirement is not installable
# evidence of anything.
for r in "${rpms[@]}"; do
    if ! rpm -qpR "$r" | grep -qx "kernel-core-uname-r = ${KVER}"; then
        echo "FATAL: $(basename "$r") does not require 'kernel-core-uname-r = ${KVER}'" >&2
        echo "       it declares:" >&2
        rpm -qpR "$r" | grep -E 'kernel-(core-)?uname-r' >&2 || echo "       (no kernel requirement at all)" >&2
        exit 1
    fi
done

echo "Installing ${#rpms[@]} kmod RPMs pinned to ${KVER}"
dnf5 install -y \
    --setopt=install_weak_deps=False \
    --setopt=tsflags=nodocs \
    "${rpms[@]}"

# depmod proves dependency ordering and that declared dependencies resolve. It is not a
# symbol checker; the load proof is Tier 2.
depmod -a "${KVER}"

# The installed RPMs must still carry the requirement, not only the files on disk.
for r in "${rpms[@]}"; do
    name="$(rpm -qp --qf '%{NAME}' "$r")"
    rpm -q --requires "$name" | grep -qx "kernel-core-uname-r = ${KVER}" \
        || { echo "FATAL: installed $name lost its kernel requirement" >&2; exit 1; }
done
