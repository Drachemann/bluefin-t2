# Next-session prompt

Paste this as the first message of a new session in `/home/matt/src/bluefin-t2`.

---

**Mode check:** you should be in **Bluefin T2** mode. If your system prompt does not say
"working in **Bluefin T2** mode", stop and tell me — the persona, the two skills and the
`linux` MCP row are not loaded, and nothing below will behave as written.

**Working directory:** `/home/matt/src/bluefin-t2`. It is not a git repository; do not
`git init`, commit or push.

**Read first, in this order:**

1. `AGENTS.md`
2. `docs/designs/kait2en-bluefin-v2.md` — §5 (the four artifacts and A2's nine steps), §6
   (resolutions: R2-3 firmware crossing, R2-9/R2-11 unit conditions and failed-boot capture),
   §9 (the tiers), §12 (open questions), §14 (T1–T15)
3. `research/findings/module-pipeline.md` — the evidence from the first session
4. `docs/runbooks/tier2-bench.md` — the bench procedure, and §0a–§0c: three recorded runs

## What is already proven — do not re-derive it

- **T1:** `t2smc` builds and signs for both kernels; it was loaded on the host
  (`7.2.11-200.fc44.x86_64`) and bound (`sensors` showed fans and 36 temperature channels).
- **T2 / A1-lite:** all **12 kmod specs / 18 objects** build, sign and package for
  `7.2.5-200.fc44.x86_64`; every RPM carries `kernel-core-uname-r = 7.2.5-200.fc44.x86_64`.
  The recipe lives in **`akmods-t2/`** (`just -f akmods-t2/Justfile build`); `.work/` was
  deleted 2026-10-21. See task 0.
- **Artifact-2 bench slice:** `Containerfile` with both stages (builder B1–B3 + image
  01–08), `build.sh`, `build_files/{01-install-kmods,19-initramfs,90-tests,build-userspace}.sh`,
  `apps/bluefin-t2` (the report), `specs/app-tree.spec.in`, `system_files/` (13 kargs, dracut
  `force_drivers`, `modules-load.d`, four `models.d` files, the four T7 units + helper +
  polkit action + group). Image `localhost/bluefin-t2-bench:7.2.5-200.fc44.x86_64`, id
  `c8d64e48…`, digest `eb31ee95…`. Eighteen Tier 0 gates pass, `bootc container lint`
  14 passed / 0 warnings. Ships the eight confirmed class-A apps, `t2remote`, the report,
  the hub, `t2-touchid`, `t2-dsp` (twelve userspace RPMs), the SELinux module at 400,
  root-side provisioning (`bluefin-t2-user-groups.service` + `.path`), and a smoke test
  that powers off only when the run asks. Tier 2 evidence, including the interactive
  session: `docs/evidence/tier2-run-2026-10-22.md`.
- **Tier 2 harness:** `harness/install-to-disk.sh`, `attempt.sh`, `evaluate.sh`,
  `provision-firmware.sh`, `rootfs/…` (units, stage loggers, smoke test), `selftest.sh`
  (84 cases, 0 failures when a usable fixture disk exists).
- **Three recorded Tier 2 runs on `MacBookPro16,2`.** The third (run `20261020T215251Z-3852`)
  passed modules 18/18, firmware, and Wi-Fi; the internal keyboard and internal trackpad
  worked, as did external USB and Bluetooth input. `systemd_failed` failed intermittently
  on `gssproxy.service` and `rpc-statd-notify.service` — both **timed out**, both sit in the
  network/NFS stack, and the same image passed that assertion on boots where Wi-Fi never
  came up. Recorded as environmental for the slice.

## Decisions already made — do not re-open

- **The firmware channel installs both name forms** (board-qualified *and* generic base
  names). Decided 2026-10-21; recorded in `research/findings/module-pipeline.md` §7 and
  runbook §3.6. Firmware still never enters the image.
- **The `systemd_failed` assertion stays strict.** The bench red is recorded, not masked;
  it is a question for the release image's own Tier 2.
- **These Tier 2 runs are not a model claim.** They are Tier 2 for a bench slice. A model
  claim needs a digest-pinned Tier 2 run of the release artifact on that model.

## Pick up here, in this order

0. **~~Before anyone deletes `.work/`: promote the kmod build out of scratch.~~ Done
   2026-10-21.** The recipe is at `akmods-t2/` (scripts, `Justfile`, `specs/kmod-t2.in`,
   `certs/`, `record/`), the four 7.2.5 kernel RPMs moved to `akmods-t2/container/rpms/`
   (hash-pinned), and `.work/` is deleted. No key material was committed. Evidence:
   `research/findings/module-pipeline.md` §8.1.
1. **~~T5's negative control~~ Done 2026-10-21.** One `force_drivers` entry was broken
   (`t2bce_dma` → `t2bce_dmax`), the slice rebuilt, and `build_files/90-tests.sh` failed at
   the `lsinitrd` gate (`GATE FAIL: initramfs is missing t2hid.ko`); the config was restored
   (`sha256 b0c6673d…`) and the slice rebuilt green with `--no-cache`. Evidence:
   `research/findings/module-pipeline.md` §8.2.
2. **~~T7 — the units, with the conditions fixed~~ Done 2026-10-21.** The four `bluefin-t2`
   units, the argument-free `provision-user` helper, the `allow_active=yes` polkit action,
   the `SHA256SUMS`-conditioned import pair, the NM bridge unit, the `kait2en-touchbar`
   group and gate 11 (+ eight negative controls) are in `system_files/`. Gate 11 passes in
   the build and `bootc container lint` is 14 passed / 0 warnings; image id `28551880…`,
   digest `sha256:7dd07715…`. Evidence: `research/findings/module-pipeline.md` §9.
   **Two design defects were found:** the R2-9 snippet puts conditions in `[Service]` where
   systemd ignores them (they must be `[Unit]` keys), and §6's description of
   `kait2en-touchbar-attach.service` does not match the actual unit. The eleven inherited
   units are still package-owned (task 3).
3. **The userspace layer** (design §5 B2/B3, §14 T4 steps 02–05). **Done 2026-10-21, all
   Tier 0:** builder stage (B1–B4), `bluefin-t2 report` (`--json`/`--markdown`/exit 0/1/2)
   and the hub (`bluefin-t2` with no arguments; nine read-only pages over the same JSON,
   `--check-gui` for the headless page model), the four `models.d` files, the confirmed
   class-A app set (eight apps + `t2remote`, ten RPMs), the SELinux module at priority 400,
   PAM fingerprint, and `MODELS.md`/`RECOVERY.md` — gates 12–16. The window itself is only
   verified on hardware (Tier 2/3). Evidence: `research/findings/userspace-layer.md`.
4. **A1 publication (T3):** the immutable `<flavor>-<fedora>-<KVER>` tag, the floating tag,
   cosign signing, and `KVER` resolution from ublue's akmods label. **Human gate:** signing,
   provenance, registry policy — ask before touching any of it.
5. **The real Artifact 2** (all nine steps) and then a **release Tier 2** on this 16,2. That
   run, not the bench runs, is what can support a model claim.
6. **Tier 3** — the macOS kit and the ISO — after that.

## Constraints that outrank the task

- **Never unload** `t2hid`, `t2bce_*` or `hid_t2magicmouse` on the running machine.
- **Never write** to `research/KaiT2en-Fedora`; it rejects AI-authored contributions.
- **Apple firmware never enters the image** — per-machine, from macOS, to `/var/lib/firmware`.
- The image is a **thin derivative** of `ghcr.io/ublue-os/bluefin@<digest>`, never a fork.
- **Never weaken** a guard, signature or provenance check to make something pass.
- **Human gates:** model claims; signing keys, MOK, provenance; the device class or the
  firmware channel; disabling a named guard; anything that writes a disk or reboots.
- No `git init` / commit / push.

## Environment facts (measured, not assumed)

- Host kernel `7.2.11-200.fc44.x86_64`; image kernel `7.2.5-200.fc44.x86_64`, read from the
  pinned base digest `sha256:23b7bf54…2bc9` — never from `uname -r`.
- Present: `podman`, `skopeo`, `dracut`, `lsinitrd`, `dnf5`, `openssl`, `rpmbuild`,
  `mokutil`, `cosign`, `just`. Absent by design: `bootc`, `rpm-ostree`, `ostree`, `buildah`.
- **The agent session has no sudo** (a password is required). Anything root-run must be
  handed to the human as exact, copy-pasteable commands.
- Bench hardware: an external USB SSD is the install target, a USB HDD labelled `K2B-HIL`
  (ext4) is the results medium, and `/dev/nvme0n1` is the internal disk — never a target.
  Device letters change between plugs; always identify by model and label.
- `podman save` cannot overwrite an existing docker-archive (`rm -f` first); `/tmp` is a
  small tmpfs, so use `/var/tmp`.
- The throwaway proof key is generated into `akmods-t2/out/keys/` by
  `just -f akmods-t2/Justfile throwaway-key` — never production, never enrol it in MOK,
  never commit it (`akmods-t2/.gitignore` covers it).

**First action:** read the four documents, then report the tree's current state and a
one-line plan for task 3 (the userspace layer). Tasks 0, 1 and 2 are finished — do not
re-open them.

## 2026-10-22 — DSP, the release image, and the install kit plan

- **Touch ID works** on `MacBookPro16,2` at the login screen with no Linux enrollment. The
  failure was the `Apple T2 Bridge` NetworkManager profile: `nm-bridge` created it with
  `autoconnect=no`, so the CDC-NCM link never came up and neither the Touch ID bridge nor
  `t2remote` could reach the T2. Fixed in the helper (create **or reconcile**, `autoconnect=true`,
  `autoconnect-retries=0`, `ipv6.method link-local`, bring it up); gate 11 asserts the semantics.
  `fix-t2-ncm.sh` on the results stick repaired the already-installed disk offline.
- **DSP:** the graphs were in the image but never selected — upstream does the selection in the
  RPM `%post`, which a multi-model image cannot do at build time. `bluefin-t2-dsp.service` now
  runs `dsp-select` at boot: DMI → `models.json` → `pipewire/<profile>.conf`, local edits
  preserved, unsupported models withdraw only our own file. Tier 0 gate covers install,
  idempotence, local-edit preservation and unknown-model withdrawal.
- **Images (both 18 gates, lint 14 passed / 1 skipped / 0 warnings):**
  - bench slice `localhost/bluefin-t2-bench:7.2.5-200.fc44.x86_64`, id `5ad0c98a…`,
    digest `sha256:a658a653…`
  - release `localhost/bluefin-t2:7.2.5-200.fc44.x86_64`, id `848c0e3e…`,
    digest `sha256:1ffbfed3…` — `build.sh --release` strips the marked harness block and gate 10
    asserts no HIL helpers, units or wants links.
- **Pending, needs the hardware:** one install of the new bench slice with
  `harness/attempt.sh --interactive` (no POWEROFF) — that is both the scored Tier 2 run for this
  change and the live session that proves the DSP (`cat /sys/class/sound/card*/id` is `t2-16_2`,
  `wpctl status` shows a `t2-162` filter chain) and re-confirms Touch ID.
- **The kit and ISO are planned, not built:** `docs/designs/bluefin-t2-install-kit.md` (BIB ISO
  from the release digest, R2-3's firmware crossing, the macOS script's steps and failure
  strings) and `docs/MAINTENANCE.md` (the dependency chain, triggers, release checklist, failure
  modes). Publication needs human decisions: registry/org, signing key, ISO volume label.
- **Kit and ISO implemented, one privileged step left:** `iso/kickstart/bluefin-t2.ks`
  (the `%post --erroronfail` firmware carry, testable body), `iso/selftest.sh` (3/3: carry,
  corrupt refusal, absent pass-through), `iso/build.sh` (BIB, refuses a bench image;
  `--dry-run` verified against the release), `kit/prepare-usb.sh` (`--check`, `--dry-run`
  verified on Linux, macOS write path), `kit/VERSION`. Mechanism decided at the first ISO
  build: payload on the USB ESP under `kait2en/firmware/wifi/` + `SHA256SUMS`, found by the
  kickstart's marker scan — R2-3's fallback, because the kit cannot build an initramfs on
  macOS and this ISO already carries the T2 input drivers. The ISO build needs `sudo`
  (BIB), which this session does not have.
- **2026-10-22, fourth interactive session: DSP and Touch ID verified on hardware.** All
  scripted lines PASS, `report` ok, hub ok: `t2-16_2` ALSA id, `t2-162` filter chain, NCM
  IPv6, `fprintd has fingerprint(s)`. The scored run failed only because the fixed
  `nm-bridge` called `nmcli connection up` unbounded and the oneshot timed out at 60 s,
  cascading into `NetworkManager-wait-online` and the greeter's user manager. Fixed with
  `timeout 15 nmcli --wait 10 connection up`, and gate 11 requires a bounded call. Images:
  bench `56d4ab3d…` / `d5c8bd85…`, release `66af6bf9…` / `be308874…`.
- **2026-10-22, noise audit and the last fixes before the final install.** Boots -3/-2/-1 had
  no failed units; the scored boot's failures were our `nm-bridge` timeout. Two inherited
  pieces were missing: `/etc/modprobe.d/kait2en-silent-blacklist.conf` (the host has it, so
  it prints no "Module X is blacklisted"; ours printed ~40 per boot) and the greeter guard
  for `kait2en-touchbar` (nine restarts on `/dev/dri/card0` permission denied). Both are now
  shipped and gated, along with the bounded `nmcli` call. Remaining noise is inherited
  (`t2magicmouse -32`, watchdog, taint), base-image (`ublue-user-setup` 127, smartcard
  core-dump) or bench-medium (`tuned`, zram at fast poweroff); the ACPI SSDT duplicate is
  ours and cosmetic, no functional symptom found. Final images: bench `4c7c15ac…` /
  `cca35b75…`, release `0ca64ed9…` / `8a890545…`. See the audit table in
  `docs/evidence/tier2-run-2026-10-22.md`.
- **2026-10-22, full log audit before the final boot.** Corrections to the earlier table: the
  ACPI `AE_ALREADY_EXISTS` duplicates and the Bluetooth `BCM.hcd` "not found" line are
  **inherited** (the host has 3 of the first and the identical second, with Bluetooth working);
  the 163 "Failed to resolve group" lines are early-boot only and runtime resolution is fine
  (reading nsswitch through its absolute symlink from the host mount gave a false negative).
  Five SELinux denials remain (`tuned_t`/`unconfined_service_t` `chcon mac_admin`, one `init_t`
  netlink getattr); none names a bluefin-t2 path. The scored smoke test now carries a fifth
  assertion, `hygiene` (zero blacklist lines, groups resolve, no btrfs errors, a Bluetooth
  controller exists), and `interactive-checks` has a system-hygiene section (failed units,
  Touch Bar restarts, AVCs, unit `Result=`, groups, hci0, inherited-noise counts). Bench
  `92a9cfe1…` / `6a8198fe…` (harness only); release unchanged at `0ca64ed9…` / `8a890545…`.
- **2026-10-22, scored run 20261021T215349Z-33e5: fail on `modules` only.** `hid_t2magicmouse`
  was sampled at 14 s but loads with the internal trackpad at ~36 s; the smoke test now waits
  up to 60 s for the declared set. Touch ID took ~20 min on the first boot because `nm-bridge`
  created the NCM profile after NetworkManager had started and NM never activated it until a
  resume; the profile now ships as a file (upstream's approach), so first boot is fast. Fixed
  images: bench `cbb7d1c0…`/`e1ed83de…`, release `3ac61195…`/`e571404f…`. A clean scored verdict
  needs one re-install of the bench image; the release image is ready for the workstation.
- **2026-10-22, the 17:22 install and the first-run flow.** First boot (`-1`) failed only on
  the accepted set (fprintd/NCM before the reboot) plus a false "not enabled globally" check;
  after the reboot (`-2`) fprintd/NCM/DSP passed, but `NetworkManager-wait-online` and the
  greeter's `user@60578` failed because `nm-bridge` rewrote the profile at every boot. The
  bridge is now idempotent, the checks accept the wants-link and treat first-session
  failures as INFO, and a first-run dialog (zenity, autostart after 20 s, `--check` gated)
  asks for the one reboot. Images: bench `241fc3fc…`/`68fec56c…`, release
  `c3c8c089…`/`b97c5d72…`. The scored verdict for the 17:22 run remains **fail** on
  `systemd_failed`; the wait-online fix is unproven on hardware until the next boot.
