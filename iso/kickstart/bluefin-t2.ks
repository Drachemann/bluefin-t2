# bluefin-t2 install ISO — the part Anaconda runs after the image is on the target.
#
# BIB embeds this file's %post in the ISO (iso/build.sh inlines it into the generated
# config). It carries the per-machine Apple firmware from the USB's ESP into the target
# ESP, where bluefin-t2-firmware-import.service picks it up on first boot (design §6 R2-3).
#
# Mechanism note (2026-10-22): R2-3 chose a second initramfs plus a dracut pre-pivot hook.
# The kit cannot build an initramfs on macOS, and this ISO is built from our own image, so
# the installer environment already has the T2 input drivers; the firmware is the only
# payload left. It travels on the USB ESP under kait2en/firmware/wifi/ with a SHA256SUMS
# marker, and this script finds that partition by the marker. That is the fallback R2-3
# names; it removes a build input (no second initramfs) and keeps the failure closed.
#
# Fail closed: if the payload exists and does not verify, the install fails while the cause
# is on screen. If it is absent, the install proceeds and first boot reports `absent`.

%post --erroronfail
# >>> firmware-post
set -euo pipefail
SYSROOT=${SYSROOT:-/mnt/sysroot}
PAYLOAD=${PAYLOAD:-}
HEADROOM=$((8 * 1024 * 1024))
log() { echo "bluefin-t2[firmware]: $*"; }

payload="$PAYLOAD"
mounts=""
cleanup() {
    # shellcheck disable=SC2086
    for m in $mounts; do umount "$m" 2>/dev/null || true; rmdir "$m" 2>/dev/null || true; done
}
trap cleanup EXIT

if [ -z "$payload" ]; then
    # The USB ESP is the only vfat partition carrying the marker. The target ESP does not
    # exist yet at this point, and every other partition is skipped by the marker test.
    for dev in /dev/disk/by-uuid/*; do
        [ -e "$dev" ] || continue
        mnt=$(mktemp -d)
        if mount -o ro "$dev" "$mnt" 2>/dev/null; then
            mounts="$mounts $mnt"
            if [ -f "$mnt/kait2en/firmware/wifi/SHA256SUMS" ]; then
                payload="$mnt/kait2en/firmware/wifi"
                break
            fi
        else
            rmdir "$mnt" 2>/dev/null || true
        fi
    done
fi

if [ -z "$payload" ] || [ ! -f "$payload/SHA256SUMS" ]; then
    log "no firmware payload found on the USB; continuing (Wi-Fi will report absent)"
    exit 0
fi

log "verifying payload from $payload"
( cd "$payload" && sha256sum -c --strict --quiet SHA256SUMS ) \
    || { log "payload checksum verification failed; refusing to finish the install"; exit 1; }

avail=$(df -B1 --output=avail "$SYSROOT/boot/efi" | tail -1)
need=$(du -sb "$payload" | cut -f1)
need=$((need + HEADROOM))
[ "$avail" -ge "$need" ] \
    || { log "target ESP too small: need $need bytes, have $avail"; exit 1; }

dst="$SYSROOT/boot/efi/kait2en/firmware/wifi"
install -d -m 0755 "$dst"
cp -a "$payload"/. "$dst"/
( cd "$dst" && sha256sum -c --strict --quiet SHA256SUMS ) \
    || { log "destination checksum verification failed"; exit 1; }

model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
payload_sha=$(sha256sum "$payload/SHA256SUMS" | cut -d' ' -f1)
install -d -m 0755 "$SYSROOT/etc/bluefin-t2"
printf '{"source":"iso/kickstart/bluefin-t2.ks","model":"%s","payload_sha256":"%s"}\n' \
    "$model" "$payload_sha" > "$SYSROOT/etc/bluefin-t2/firmware-import.json"
log "carried firmware to $dst"
# <<< firmware-post
%end
