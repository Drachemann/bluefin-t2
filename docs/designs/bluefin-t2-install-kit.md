# The bluefin-t2 install kit — implementation plan

Status: **plan, not built.** Design of record: `docs/designs/kait2en-bluefin-v2.md` §6 R2-3
(firmware across the install boundary), §7 (the install journey) and §9 Tier 3. This page turns
those decisions into the files to write and the order to prove them in. Nothing here changes a
decision; where it differs from R2-3 it says so.

## The shape

Three artifacts, in the order they are made:

| Artifact | Made by | Contains | Proved by |
|---|---|---|---|
| **Release image** | `build.sh --release` | the product, no Tier 2 harness | Tier 0 gates + a scored Tier 2 run on the bench slice |
| **ISO** | `bootc-image-builder` against the release digest | the installer environment **and the product image** | boot to installer, install, first boot |
| **Kit** | `kit/prepare-usb.sh` on macOS | firmware capture, ISO download/verify, USB write, ESP injection | `--check` on macOS, then a Tier 3 run |

Building the ISO with BIB from *our* image is the one real difference from KAIT2EN's kit, and it
is a simplification, not a fork: t2-atomic already does it this way
(`research/t2-atomic/disk_config/iso-bluefin.toml`, `Justfile:210`). Because the live environment
is built from our image, **the T2 keyboard and trackpad work in the installer without the ESP
initramfs injection** — KAIT2EN needed that injection only because it boots a stock Fedora ISO
whose kernel has no T2 drivers. What our live environment still needs is the **firmware payload**,
which is exactly what R2-3's second initramfs and post-script are for.

## Components to write

### `iso/iso.toml` — the BIB config

```toml
[customizations.installer.kickstart]
contents = """
%include /run/install/repo/kait2en-firmware.ks
"""
```

The payload is the same `%post --erroronfail` R2-3 specifies: copy
`/run/kait2en/apple-firmware/*` to `/mnt/sysroot/boot/efi/kait2en/firmware/wifi/`, write
`SHA256SUMS`, check free space on the *target* ESP, write `firmware-import.json`, and fail the
install if the source exists and the copy or checksum does not verify.

BIB embeds the kickstart in the ISO, so the kickstart is a build input, not a USB edit. The
per-machine part (the firmware itself) is still supplied by the kit at USB-write time.

### `iso/build.sh` — one invocation, pinned

`bootc-image-builder` from a pinned image digest, `--type iso`, `--rootfs`/`--use-librepo` as the
t2-atomic recipe has them, reading the release image from rootful podman storage. Output:
`bluefin-t2-<kver>-<release-id>.iso`, `SHA256SUMS`, and a `build-info.json` naming the image
digest it was built from. The ISO is **rebuilt per release**, never reused across image digests.

### `kit/prepare-usb.sh` — the macOS script

One executable, POSIX-ish bash (macOS `/bin/bash` 3.2 is the constraint — no associative arrays,
no `mapfile`), with these steps and these failure strings:

1. `--check` — verify the ISO's SHA-256, capture the firmware, print the four filenames, board,
   model and the "these cannot be downloaded later" sentence, check the target disk's size and
   format, and write nothing.
2. Firmware capture — `/usr/share/firmware/wifi/{*.trx,*.clmb,*.txcb,P-*.txt}`, `--firmware-dir`
   for a prepared directory, the best message kept verbatim: "Enable Wi-Fi, reboot macOS, and
   retry, or use `--firmware-dir`".
3. Typed confirmation — `ERASE diskN`; media name, capacity, "needed / available" per row.
4. Write the ISO (`dd`), re-read and verify, then inject the payload into the USB ESP:
   `kait2en/apple-firmware/` plus the `kait2en-wifi-initramfs.img` that R2-3's dracut hook reads.
   Every file is `cmp`'d after the write.
5. Render the closing block: Option-boot, the keyboard will work, the post-script copies the
   payload, first login reports the import.

No `curl | bash`; the documented path downloads, verifies with `shasum -c`, and runs the file.

### `system_files/usr/libexec/bluefin-t2/dracut/90-kait2en-updates.sh` — the pre-pivot hook

Inherited verbatim from `research/KaiT2en-Fedora/auto-installer/initramfs/90-kait2en-updates.sh`
(the comment "Nothing placed here reaches the installed system" stays true and is the reason the
post-script exists). It copies the second initramfs to `/run/kait2en/apple-firmware` in the live
environment. Whether BIB's dracut runs it is **the one unproven mechanism**, the same open question
R2-3 names for Anaconda's updates image; Tier 3 decides it, and the fallback is the kit writing the
payload to the USB ESP and the kickstart mounting that ESP by label.

## Why not a stock Bluefin ISO plus `bootc switch`

Two reasons. A `bootc switch` runs after the stock installer has already partitioned and written a
Bluefin deployment; it needs the registry and the signature policy at install time, and it leaves
the stock installer's decisions in place. BIB's ISO installs the product image directly, offline,
with no registry — which is also what makes the kit testable before publication. The stock-ISO
route stays documented as route 2 (no macOS) in `RECOVERY.md`.

## What is written now (2026-10-22)

| File | State |
|---|---|
| `iso/kickstart/bluefin-t2.ks` | the `%post --erroronfail` transfer, with markers so the same body is testable |
| `iso/selftest.sh` | **3/3 passing**: carry + checksum, corrupt payload refused, absent payload proceeds |
| `iso/build.sh` | BIB invocation + release-shape refusal; `--dry-run` verified against release `848c0e3e…` |
| `kit/prepare-usb.sh` | `--check` / `--dry-run` / write path; `--dry-run` verified on Linux, `--help` verified |
| `kit/VERSION` | the image release the kit supports |
| `iso/selftest.sh` (TOML half) | the generated BIB config is legal TOML and carries the `%post` |

**Mechanism decided at the first ISO build** (the call R2-3 left open): the kit writes the
payload to the USB ESP under `kait2en/firmware/wifi/` with `SHA256SUMS`, and the kickstart
finds that partition by the marker. The second-initramfs mechanism is not used: the kit cannot
build an initramfs on macOS, and this ISO is built from our image, so the live environment
already has the T2 input drivers and the firmware is the only payload left. R2-3's fallback is
now the primary path; the fail-closed and absent-payload behaviours are unchanged and tested.

The ISO build itself needs `sudo` (BIB is a privileged rootful container), and the release
image must be transferred to rootful storage first. That is the one remaining step for the
artifact; the scored Tier 2 run and the live DSP check need the hardware.

## Order of work

1. `iso/iso.toml` + `iso/build.sh`; build an ISO from release `848c0e3e…` and inspect it (Tier 0:
   the ISO's live environment carries `t2hid`, the five input objects, `dsp-select`, no HIL
   units).
2. The pre-pivot hook and the kickstart post-script; Tier 0 fixture test of the post-script on a
   fake `/mnt/sysroot` (copy, checksum, free-space refusal, missing-source pass-through).
3. The macOS kit: `--check` and the write path; second-machine review because no Linux CI can run
   macOS `diskutil`.
4. Tier 3: one real USB, no external hardware, the four assertions R2-3 names, plus the three
   negative runs.

## Open questions for the human

1. **Registry and org** for publication (`ghcr.io/<org>/bluefin-t2`, `akmods-t2`) — needed before
   the ISO's image reference can be a published digest rather than a local one.
2. **Signing**: the throwaway key must be replaced before any ISO is offered; the DER in the image,
   the cosign key, and the MOK enrolment screen all depend on that decision.
3. **ISO volume label and boot entry name** (`bluefin-t2`), since it is user-visible and the
   trademark rule applies.
