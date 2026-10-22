#!/bin/bash
# run.sh — host-side orchestrator for the A1 proof build.
#
# Usage: run.sh [--kver KVER] [--digest SHA256] [--out DIR] [--key-dir DIR]
#               [--src-dir DIR] [--image IMAGE] [--no-verify] [--no-stage]
#
# One command, in this order: resolve the target kernel, stage the pinned sources, make
# sure the proof container exists, build/sign/package inside it, then verify the packaged
# artifacts from outside it with verify-artifacts.sh. No sudo, no host package installs,
# no module is ever loaded (the container shares the host kernel, and everything the
# build does is read-only with respect to that kernel).
#
# KVER resolution is the design's rule (R2-13): read it from the pinned base digest's
# `ostree.linux` label, never from `uname -r` and never from a floating tag. --kver
# exists for a deliberate override and prints a warning, because the container's
# kernel-devel tree must match it.
#
# The signing key is NEVER in this repository. Point --key-dir at a directory holding
# `signing.key` + `signing.pem`; `just throwaway-key` generates a clearly-labelled
# throwaway pair under out/keys/ for proof builds. A production key is offline and its
# use is a human gate (design §5).

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AKMODS=$(cd "$HERE/.." && pwd)
ROOT=$(cd "$AKMODS/.." && pwd)

BASE_IMAGE="${BASE_IMAGE:-ghcr.io/ublue-os/bluefin}"
BASE_TAG="${BASE_TAG:-stable}"
KVER=""
DIGEST=""
OUT="$AKMODS/out"
KEY_DIR="$AKMODS/out/keys"
SRC_DIR="$ROOT/.build/src"
IMAGE=""
VERIFY=1
STAGE=1

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (( $# )); do
    case "$1" in
        --kver)     KVER="${2:?--kver needs a value}"; shift 2 ;;
        --digest)   DIGEST="${2:?--digest needs a value}"; shift 2 ;;
        --out)      OUT="${2:?--out needs a directory}"; shift 2 ;;
        --key-dir)  KEY_DIR="${2:?--key-dir needs a directory}"; shift 2 ;;
        --src-dir)  SRC_DIR="${2:?--src-dir needs a directory}"; shift 2 ;;
        --image)    IMAGE="${2:?--image needs a tag}"; shift 2 ;;
        --no-verify) VERIFY=0; shift ;;
        --no-stage)  STAGE=0; shift ;;
        -h|--help)  usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

command -v podman >/dev/null || { echo "FATAL: podman required" >&2; exit 1; }
command -v skopeo >/dev/null || { echo "FATAL: skopeo required" >&2; exit 1; }
command -v jq     >/dev/null || { echo "FATAL: jq required" >&2; exit 1; }

# --- 1. the target kernel --------------------------------------------------------------
if [[ -z "$KVER" ]]; then
    if [[ -z "$DIGEST" ]]; then
        echo ">> resolving ${BASE_IMAGE}:${BASE_TAG} to a digest"
        DIGEST="$(skopeo inspect "docker://${BASE_IMAGE}:${BASE_TAG}" | jq -r '.Digest')"
    fi
    [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "FATAL: not a digest: '$DIGEST'" >&2; exit 1; }
    echo "   base digest: ${DIGEST}"
    KVER="$(skopeo inspect "docker://${BASE_IMAGE}@${DIGEST}" | jq -r '.Labels["ostree.linux"]')"
    echo "   kernel from the digest label: ${KVER}"
else
    echo ">> WARNING: --kver ${KVER} overrides the digest label; the container must carry"
    echo "   kernel-devel for exactly that release or the build will use the wrong headers."
    DIGEST="${DIGEST:-<override, not resolved from a digest>}"
fi
[[ "$KVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+-.*\.x86_64$ ]] \
    || { echo "FATAL: ostree.linux label missing or unusable: '$KVER'" >&2; exit 1; }
echo "   host runs: $(uname -r)  (irrelevant on purpose — vermagic is the identity)"

# --- 2. the signing key, which is never in this repository ----------------------------
KEY_FILE="$KEY_DIR/signing.key"
CERT_FILE="$KEY_DIR/signing.pem"
if [[ ! -f "$KEY_FILE" || ! -f "$CERT_FILE" ]]; then
    cat >&2 <<EOF
FATAL: no signing key pair in $KEY_DIR

  expected: $KEY_FILE
            $CERT_FILE

Key material is never committed. For a proof build:
  just -f $AKMODS/Justfile throwaway-key
and read the warning it prints. A production key is an offline artifact and using it is
a human gate; do not point this at one without that decision.
EOF
    exit 1
fi
CN=$(openssl x509 -in "$CERT_FILE" -noout -subject -nameopt sep_multiline 2>/dev/null \
        | sed -n 's/^ *CN *= *//p' | head -1)
[[ -n "$CN" ]] || { echo "FATAL: cannot read a CN from $CERT_FILE" >&2; exit 1; }
echo "   signing certificate: $CN"

# --- 3. stage the pinned sources -------------------------------------------------------
if (( STAGE )); then
    echo ">> staging sources from the pinned KAIT2en clone"
    "$HERE/stage-sources.sh" --target "$SRC_DIR"
else
    [[ -d "$SRC_DIR" ]] || { echo "FATAL: --no-stage but $SRC_DIR does not exist" >&2; exit 1; }
    echo ">> using staged sources in $SRC_DIR (--no-stage)"
fi

# --- 4. the proof container ------------------------------------------------------------
IMAGE="${IMAGE:-localhost/bluefin-t2-proof:${KVER}}"
if podman image exists "$IMAGE"; then
    echo ">> proof container present: $IMAGE"
else
    echo ">> building proof container $IMAGE from container/"
    "$HERE/fetch-kernel-rpms.sh" --check
    podman build -t "$IMAGE" "$AKMODS/container"
fi

# --- 5. build, sign, package, and verify inside the container -------------------------
mkdir -p "$OUT"
# Podman treats a relative bind source as a named volume, so every mount source must be
# absolute. OUT/KEY_DIR are resolved here; SRC_DIR after staging.
OUT="$(cd "$OUT" && pwd)"
KEY_DIR="$(cd "$KEY_DIR" && pwd)"
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
echo ">> building 12 specs / 18 objects for $KVER in $IMAGE"
set +e
podman run --rm \
    -v "$SRC_DIR:/src:ro,z" \
    -v "$AKMODS/specs:/specs:ro,z" \
    -v "$KEY_DIR:/keys:ro,z" \
    -v "$OUT:/out:z" \
    -v "$HERE/build-all.sh:/build-all.sh:ro,z" \
    "$IMAGE" bash /build-all.sh "$KVER" \
    > "$OUT/build.log" 2>&1
RC=$?
set -e

echo ">> container exit: $RC (0 = all 12 specs built; N = N specs failed)"
# Diagnostic only: a failed build has no PASS lines, and grep's own exit status must not
# abort the script before it can report and record the failure (the pipefail trap).
grep -E '^(PASS|FAIL) |^RESULT:|^ALL EXPECTED|^INCOMPLETE' "$OUT/build.log" | tail -40 || true

# --- 6. verify the packaged artifacts from outside ------------------------------------
if (( RC == 0 && VERIFY )); then
    echo
    VERIFY_EXTRA=()
    # --exact pins the signed bytes to the recorded canonical artifact set, which is only
    # true when writing into the canonical out/ dir. A rebuild elsewhere is still held to
    # the key-independent content record.
    if [[ "$(cd "$OUT" && pwd)" == "$AKMODS/out" ]]; then
        VERIFY_EXTRA+=(--exact)
    else
        echo ">> output is not the canonical $AKMODS/out — verifying content reproducibility only"
    fi
    "$HERE/verify-artifacts.sh" "$OUT/rpms" "$KVER" "$CERT_FILE" --record "$AKMODS/record" "${VERIFY_EXTRA[@]}"
fi

# --- 7. record what was built ----------------------------------------------------------
{
    echo "kver=${KVER}"
    echo "base_image=${BASE_IMAGE}"
    echo "base_digest=${DIGEST}"
    echo "container=${IMAGE}"
    echo "signing_cn=${CN}"
    echo "built=$(date -Is)"
    echo "container_exit=${RC}"
} > "$OUT/BUILD.txt"
echo "recorded: $OUT/BUILD.txt"

if (( RC != 0 )); then
    echo "FATAL: $RC spec(s) failed to build — see $OUT/build.log and $OUT/STATUS.md" >&2
fi
exit "$RC"
