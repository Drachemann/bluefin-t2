#!/usr/bin/bash
# iso/build.sh — build the bluefin-t2 install ISO from the release image.
#
# The ISO is built by bootc-image-builder (BIB) from the *release* image, the same way
# t2-atomic builds its ISO (research/t2-atomic/Justfile:210). The product image is embedded,
# so the installer needs no registry, and the live environment carries our kernel, our T2
# input modules and our userspace.
#
#   ./iso/build.sh [--dry-run] [--image REF] [--out DIR]
#
# Requires: podman, sudo (BIB is a privileged rootful container), the release image in
# rootful podman storage.

set -euo pipefail

IMAGE="${IMAGE:-localhost/bluefin-t2:7.2.5-200.fc44.x86_64}"
OUT_DIR="${OUT_DIR:-iso/out}"
BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
KS="iso/kickstart/bluefin-t2.ks"
DRY_RUN=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "iso/build.sh: $*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --image)   IMAGE="${2:?--image needs a value}"; shift 2 ;;
        --out)     OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
        -h|--help) usage 0 ;;
        *) echo "iso/build.sh: unknown argument: $1" >&2; usage 1 ;;
    esac
done

command -v podman >/dev/null || die "podman is required"
[[ -f "$KS" ]] || die "missing $KS"
grep -q '"""' "$KS" && die "$KS contains a TOML-breaking triple quote"

# The ISO is only ever built from a release image: a bench slice would install the harness
# on the user's machine. Refuse before spending a build on it.
podman run --rm --entrypoint /usr/bin/bash "$IMAGE" -c \
    'test ! -e /usr/lib/systemd/system/bluefin-t2-hil-test.service' \
    || die "$IMAGE carries the Tier 2 harness; build with ./build.sh --release"

image_id=$(podman image inspect --format '{{.Id}}' "$IMAGE")
short=${image_id#sha256:}
short=${short:0:12}
iso_name="bluefin-t2-${short}.iso"

work=$(mktemp -d)
out=$(mktemp -d)
trap 'rm -rf "$work" "$out"' EXIT

# BIB takes the kickstart as an inline TOML string. The file is the single source of truth;
# iso/selftest.sh runs the same %post body against fixtures.
config="$work/config.toml"
{
    echo '[customizations.installer.kickstart]'
    echo 'contents = """'
    cat "$KS"
    echo '"""'
} > "$config"

run=(
    sudo podman run --rm --privileged --pull=newer --net=host
    --security-opt label=type:unconfined_t
    -v "$config":/config.toml:ro
    -v "$out":/output
    -v /var/lib/containers/storage:/var/lib/containers/storage
    "$BIB_IMAGE"
    --type iso --use-librepo=True --rootfs=btrfs
    --config /config.toml
    "$IMAGE"
)

if (( DRY_RUN )); then
    echo "DRY RUN — would build $iso_name from $IMAGE ($image_id)"
    printf '  %q' "${run[@]}"
    echo
    exit 0
fi

command -v sudo >/dev/null || die "sudo is required for BIB"
mkdir -p "$OUT_DIR"
echo ">> building $iso_name with $BIB_IMAGE"
"${run[@]}"
[[ -f "$out/$iso_name" ]] || { ls -l "$out" >&2; die "BIB did not produce $iso_name"; }
install -m 0644 "$out/$iso_name" "$OUT_DIR/$iso_name"
( cd "$OUT_DIR" && sha256sum "$iso_name" > "$iso_name.sha256" )
echo "built:    $OUT_DIR/$iso_name"
echo "sha256:   $(cut -d' ' -f1 "$OUT_DIR/$iso_name.sha256")"
echo "image:    $IMAGE ($image_id)"
