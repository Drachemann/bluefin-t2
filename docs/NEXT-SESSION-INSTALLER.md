# New-session prompt — the real installer, hosted on GitHub

Paste this as the first message of a new session in `/home/matt/src/bluefin-t2`.

---

**Mode check:** you should be in **Bluefin T2** mode. If your system prompt does not say
"working in **Bluefin T2** mode", stop and tell me — the persona, the skills and the `linux`
MCP row are not loaded.

**Working directory:** `/home/matt/src/bluefin-t2`. It is now a git repository on `main`,
remote `git@github.com:Drachemann/bluefin-t2.git`. Do not rewrite history; one logical change
per commit, staged by explicit filename. The reference clones under `research/` are **not**
committed: run `research/fetch.sh` (pins in `research/PINS.md`) before building. Never write
to `research/KaiT2en-Fedora`, and never commit key material or Apple firmware.

**Read first, in this order:** `AGENTS.md`; `docs/designs/kait2en-bluefin-v2.md` (§6 R2-3
firmware crossing, §7 the install journey and first-login surfaces, §9 Tier 3, §14 tasks);
`docs/designs/bluefin-t2-install-kit.md`; `docs/MAINTENANCE.md`;
`docs/evidence/tier2-run-2026-10-22.md`; `docs/NEXT-SESSION.md`.

## What already exists (do not re-derive)

- **Image:** `localhost/bluefin-t2:7.2.5-200.fc44.x86_64`, id `c3c8c089…`, digest
  `sha256:b97c5d72…`; bench slice `241fc3fc…` / `sha256:68fec56c…`. Both pass the 18 Tier 0
  gates and `bootc container lint` (14/1/0). The release image has no Tier 2 harness.
- **Verified on `MacBookPro16,2`:** modules, firmware-backed Wi-Fi, Touch Bar, Touch ID at
  login (from the second boot), DSP graph (`t2-16_2` card + filter chain), suspend/resume,
  fan/thermal, the hub and `report`. The one-reboot first boot is accepted as KaiT2EN's
  behaviour; a first-run dialog now asks for it (`/usr/libexec/bluefin-t2/first-run`,
  autostart, `--check` gated).
- **Firmware:** per-machine, captured from macOS, carried by the kit, imported on first boot
  from `/boot/efi/kait2en/firmware/wifi/SHA256SUMS` into `/var/lib/firmware` with
  `firmware_class.path=`. Never in the image.
- **Signing:** only a throwaway proof key exists (`akmods-t2/out/keys`, ignored, never
  committed). Publication and the real key are human gates.
- **Install kit code:** `kit/prepare-usb.sh` (`--check`/`--dry-run` verified on Linux),
  `iso/kickstart/bluefin-t2.ks` (firmware `%post`, `iso/selftest.sh` 3/3), `iso/build.sh`
  (BIB from the release digest, `--dry-run` verified). The ISO itself has not been built.

## The mission

Make the installer real and host it on GitHub, mirroring KaiT2EN's macOS flow as closely as
possible: one script downloaded from the repo's latest release, run on macOS with only a USB
target, which downloads the ISO, captures this Mac's Apple firmware, writes the USB, modifies
the USB image/installer, and tells the user to reboot and install; the installed system then
does its post-install work (first-run dialog + reboot).

Deliver in this order, and **do not write the installer before the ISO decision is made and
reviewed**:

1. **Stand up the GitHub delivery surface.** The repo is `Drachemann/bluefin-t2` (public,
   empty at the time this prompt was written). Decide and record: release workflow
   (`gh release create` with `install-bluefin-t2.sh`, `SHA256SUMS`), GHCR publication for the
   image (org/repo names, visibility), and where the ISO lives. The hard limit to verify, not
   assume: **GitHub Releases assets are capped at 2 GiB per file**; a Bluefin ISO may exceed
   it. If it does, pick a second home (Forgejo/object storage) and say so; do not silently
   ship a broken link.
2. **The ISO decision, as a gstack plan review before code.** Two candidate architectures,
   both grounded in the tree:
   - **(A) Stock Bluefin Classic ISO, KaiT2EN-style.** Investigate what the stock ISO actually
     is (Bluefin Classic's installer, Anaconda vs bootc-image-builder/ISO, its live kernel
     version). If it can be used: the kit must inject the T2 input modules built **for that
     ISO kernel** into the ESP's initramfs + GRUB entry (the KAIT2EN pattern), carry the
     firmware in the second initramfs or the ESP payload, and arrange the installed system to
     be **our** image (kickstart `bootc switch`/`bootc install --target-imgref` to the hosted
     digest, or a post-install script). This is the closest to KaiT2EN and needs a second
     kmod build target.
   - **(B) BIB ISO from our release image.** `iso/build.sh` already knows how; the live
     environment then has the T2 input drivers and the firmware post-script works. Simpler,
     but not "the stock Bluefin ISO".
   Decide with evidence from `research/bluefin`, `research/t2-atomic` (`disk_config/iso-bluefin.toml`,
   `Justfile:210`), `research/KaiT2en-Fedora/auto-installer/` and current Bluefin/BIB docs,
   under `/gstack-plan-eng-review`. Record the decision in the kit design doc.
3. **The kit script**, matching the decided architecture: macOS bash 3.2, `--check`,
   `--iso PATH`, `--firmware-dir`, `--disk diskN`, typed `ERASE diskN`, firmware capture with
   the four filenames, ISO checksum verification, USB write + read-back, ESP injection,
   GRUB/initramfs edits, and a closing block that tells the user what happens next. The
   documented download path is fetch + verify + run, not a blind pipe to a shell (KaiT2EN
   prints the same warning).
4. **The install-time transfer and first boot**: the R2-3 update/post-script mechanism for the
   chosen ISO, the target ESP assertions (four files, `SHA256SUMS`, `firmware-import.json`),
   and the first-run dialog path.
5. **CI**: a workflow that builds the image, runs the Tier 0 gates, and publishes the image
   and the release assets — **without** ever publishing signing keys or firmware. Any
   workflow that must skip a signature check is wrong.
6. **Docs**: `INSTALL.md` (the stranger path), `FIRMWARE.md`, `KIT-REFERENCE.md`, and the
   maintenance page update. Only describe what the Tier 3 run actually exercised.

## Verification

Tier 3 is the gate: one real USB, no external hardware, the real ISO, a clean install; then
mount the target ESP and assert the firmware payload, boot and assert Wi-Fi, Touch ID (second
boot), DSP, and the first-run dialog. Negative runs: wrong-board payload refused, ESP full,
USB pulled mid-install. The repo's own gates must pass on every build.

## Human gates — stop and ask

Registry/org and image publication; the real signing key, MOK ceremony and provenance;
the firmware channel; a model claim (only a digest-pinned Tier 2 run for that model); any
build unblocked by disabling a named guard; any command that reboots, installs to, or writes
a disk on the machine.

## gstack

Record the objective with `gstack_pipeline` **before the first gate**. Use
`gstack_route_skill` for stage decisions, `/gstack-plan-eng-review` for the ISO architecture
and the kit contract, `/gstack-review` on the script and the workflow, and `/gstack-ship`
only after the human gates above. `gstack-qa`/`gstack-browse` do not apply here: there is no
browser surface.
