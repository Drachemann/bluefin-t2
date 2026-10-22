#!/usr/bin/bash
# bluefin-t2 bench image driver.
#
#   ./build.sh [--release] [--dry-run] [--tag TAG] [--kmods DIR] [--digest SHA256] [--no-cache]
#
# --release strips the marked bench-only harness layer and builds the product image
# (localhost/bluefin-t2:<kver>); without it the bench slice is built.
#
# Resolves the base image to a DIGEST, reads the target KVER from that digest's
# `ostree.linux` label (never from uname -r, never from a floating tag), asserts every
# kmod RPM is pinned to that exact kernel, stages the build context and builds.
#
# The resolution is the design's rule (R2-13): the image's kernel comes from the pinned
# base digest. Reading `uname -r` here would silently build for the wrong kernel and
# produce modules that fail to load with "invalid module format" — the project's most
# common real failure.

set -euo pipefail

BASE_IMAGE="${BASE_IMAGE:-ghcr.io/ublue-os/bluefin}"
BASE_TAG="${BASE_TAG:-stable}"
KMODS_DIR="${KMODS_DIR:-akmods-t2/out/rpms}"
CONTEXT_DIR=""
RELEASE=0
DIGEST=""
TAG=""
DRY_RUN=0
BUILD_EXTRA=()

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (( $# )); do
    case "$1" in
        --release) RELEASE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --tag)     TAG="${2:?--tag needs a value}"; shift 2 ;;
        --kmods)   KMODS_DIR="${2:?--kmods needs a value}"; shift 2 ;;
        --digest)  DIGEST="${2:?--digest needs a value}"; shift 2 ;;
        --no-cache) BUILD_EXTRA+=(--no-cache); shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
done

command -v skopeo >/dev/null || { echo "FATAL: skopeo required" >&2; exit 1; }
command -v podman >/dev/null || { echo "FATAL: podman required" >&2; exit 1; }
command -v jq     >/dev/null || { echo "FATAL: jq required" >&2; exit 1; }

# --- 1. pin the base image ------------------------------------------------------------
if [[ -z "$DIGEST" ]]; then
    echo ">> resolving ${BASE_IMAGE}:${BASE_TAG} to a digest"
    DIGEST="$(skopeo inspect "docker://${BASE_IMAGE}:${BASE_TAG}" | jq -r '.Digest')"
fi
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] \
    || { echo "FATAL: not a digest: '$DIGEST'" >&2; exit 1; }
echo "   base digest: ${DIGEST}"

# --- 2. the kernel comes from that digest's label, not from this machine --------------
KVER="$(skopeo inspect "docker://${BASE_IMAGE}@${DIGEST}" | jq -r '.Labels["ostree.linux"]')"
[[ "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+-.*\.x86_64$ ]] \
    || { echo "FATAL: ostree.linux label missing or unusable on ${DIGEST}: '$KVER'" >&2; exit 1; }
echo "   target kernel: ${KVER}  (host runs: $(uname -r))"

# --- 3. the kmods must be pinned to that kernel, before anything is built -------------
shopt -s nullglob
rpms=("${KMODS_DIR}"/*.rpm)
if (( ${#rpms[@]} == 0 )); then
    echo "FATAL: no kmod RPMs in ${KMODS_DIR}." >&2
    echo "       Build them first (A1) for ${KVER}: just -f akmods-t2/Justfile build" >&2
    echo "       The image cannot invent its modules." >&2
    exit 1
fi
for r in "${rpms[@]}"; do
    if ! rpm -qpR "$r" | grep -qx "kernel-core-uname-r = ${KVER}"; then
        echo "FATAL: $(basename "$r") is not pinned to ${KVER}" >&2
        rpm -qpR "$r" | grep -E 'kernel-(core-)?uname-r' >&2 || true
        exit 1
    fi
done
echo "   ${#rpms[@]} kmod RPMs, all pinned to ${KVER}"

if (( RELEASE )); then
    VARIANT=release
    TAG="${TAG:-localhost/bluefin-t2:${KVER}}"
else
    VARIANT=bench
    TAG="${TAG:-localhost/bluefin-t2-bench:${KVER}}"
fi
CONTEXT_DIR=".build/${VARIANT}-image/context"
RECORD=".build/${VARIANT}-image/BUILT.txt"

if (( DRY_RUN )); then
    echo
    echo "DRY RUN — would stage ${CONTEXT_DIR} and build ${TAG} (RELEASE=${RELEASE})"
    echo "  podman build --tag ${TAG} \\"
    echo "      --build-arg BASE_IMAGE=${BASE_IMAGE} \\"
    echo "      --build-arg BASE_DIGEST=${DIGEST} \\"
    echo "      --build-arg KVER=${KVER} \\"
    echo "      --build-arg RELEASE=${RELEASE} \\"
    echo "      --file ${CONTEXT_DIR}/Containerfile ${CONTEXT_DIR}"
    exit 0
fi

# --- 4. stage the context (podman COPY cannot reach outside it) ----------------------
rm -rf "$CONTEXT_DIR"
mkdir -p "${CONTEXT_DIR}/rpms"
if (( RELEASE )); then
    # Strip the marked harness block. The markers are the single source of truth: the
    # release image must not carry stage loggers, HIL units or their wants links, and
    # 90-tests.sh asserts the correct shape for whichever variant it is running in.
    awk '/^# >>> bench-only-harness$/{skip=1; next}
         /^# <<< bench-only-harness$/{skip=0; next}
         !skip' Containerfile > "${CONTEXT_DIR}/Containerfile"
    if grep -q 'bench-only-harness' "${CONTEXT_DIR}/Containerfile"; then
        echo "FATAL: failed to strip the bench-only harness block" >&2; exit 1
    fi
else
    cp Containerfile "${CONTEXT_DIR}/Containerfile"
fi
cp -a build_files system_files "${CONTEXT_DIR}/"
# Our own userspace tree and the packaging template the builder stage renders.
cp -a apps specs "${CONTEXT_DIR}/"
# The pinned KAIT2EN sources, without the clone's history: the builder stage consumes
# them as source (B2), and the design's boundary is a pinned submodule, not a fork.
mkdir -p "${CONTEXT_DIR}/kait2en"
cp -a research/KaiT2en-Fedora/. "${CONTEXT_DIR}/kait2en/"
rm -rf "${CONTEXT_DIR}/kait2en/.git"
# The bench-only harness layer: stage loggers, smoke test, three units. A bench image
# without them cannot report what happened; the release image has already stripped the
# COPY that installs them.
if (( ! RELEASE )); then
    cp -a harness/rootfs "${CONTEXT_DIR}/rootfs"
fi
cp "${rpms[@]}" "${CONTEXT_DIR}/rpms/"

# The PUBLIC module-signing certificate travels with the image: `mokutil --import` needs a
# DER in the filesystem, and `bluefin-t2 report` uses its presence to tell on-not-enrolled
# from on-unknown (design §7 lifecycle). Public material only — A1's private key never
# leaves akmods-t2/out/keys and is never staged here.
SIGNING_DER="${SIGNING_DER:-akmods-t2/out/keys/signing.der}"
if [[ ! -s "$SIGNING_DER" ]]; then
    echo "FATAL: no signing DER at $SIGNING_DER (run: just -f akmods-t2/Justfile build)" >&2
    exit 1
fi
mkdir -p "${CONTEXT_DIR}/certs"
install -m 0644 "$SIGNING_DER" "${CONTEXT_DIR}/certs/bluefin-t2.der"
sha256sum "${CONTEXT_DIR}/certs/bluefin-t2.der" | cut -d' ' -f1 \
    > "${CONTEXT_DIR}/certs/bluefin-t2.der.sha256"

# --- 5. build -------------------------------------------------------------------------
echo ">> building ${TAG}"
podman build \
    "${BUILD_EXTRA[@]}" \
    --tag "$TAG" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "BASE_DIGEST=${DIGEST}" \
    --build-arg "KVER=${KVER}" \
    --build-arg "RELEASE=${RELEASE}" \
    --file "${CONTEXT_DIR}/Containerfile" \
    "${CONTEXT_DIR}"

# --- 6. record what was built, tied to the digest and the kernel ---------------------
image_id="$(podman image inspect --format '{{.Id}}' "$TAG")"
echo
echo "built:    ${TAG}"
echo "image id: ${image_id}"
echo "base:     ${BASE_IMAGE}@${DIGEST}"
echo "kernel:   ${KVER}"
podman image inspect --format '{{json .Labels}}' "$TAG" | jq .

mkdir -p "$(dirname "$RECORD")"
{
    echo "tag=${TAG}"
    echo "image_id=${image_id}"
    echo "base_image=${BASE_IMAGE}"
    echo "base_digest=${DIGEST}"
    echo "kver=${KVER}"
    echo "built=$(date -Is)"
} > "$RECORD"
echo "recorded: $RECORD"
