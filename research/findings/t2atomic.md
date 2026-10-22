# t2-atomic (kansei-os) — source analysis

**Snapshot:** `d8b3ee7` (`2026-10-13`, shallow clone, 1 commit — no history available), `origin=https://github.com/kansei-os/t2-atomic`. Tree is 4,711 lines of text plus one 12 MB binary `build_files/common/radio.tar`.
**Comparison trees:** `bluefin@13efd26` (2026-10-16), `akmods@d3958bd` (2026-10-15), `KaiT2en-Fedora@ba9d2d8` (2026-10-20).

**Citation convention:** bare names (`README:47`, `Containerfile:30`, `t2-enablement-ublue.sh:69`) resolve inside `research/t2-atomic`; `KaiT2en-Fedora` sources are always written with their path (`README.md:4`, `t2-services/README.md:44-52`). `…:NN-MM` is inclusive.

## Executive summary

1. t2-atomic is **not** blue-build: it is a plain **Containerfile-per-variant + bootc** repo (11 variant Containerfiles + 1 root, 12 `build-image-*` workflows, 3 `build-iso-*`, `Justfile` for local/BIB builds). README:22 calls it "a fork of T2 Atomic … which was based on rpm-ostree and blue-build.org tooling", i.e. a ground-up rebuild of the older blue-build project.
2. The **T2 mechanism is one shared shell script** (`build_files/t2-enablement*.sh`) that swaps the base kernel for the `sharpenedblade/t2linux` COPR kernel via `rpm-ostree override replace --experimental --freeze`, then installs `t2fanrd` + `t2linux-release` + (some variants) `t2-touchid` (t2-enablement-ublue.sh:34-44).
3. It ships **no modules of its own, no DKMS, no akmods**: all T2 kernel code comes from the COPR kernel RPM, whose contents the repo never enumerates. "T2 module coverage" is therefore largely **not stated in tree**.
4. Apple firmware is **baked in as files**: `radio.tar` (163 files, 12,185,600 B) extracted to `/lib/firmware/brcm` (t2-enablement-ublue.sh:65-66), plus one variant path that curls `brcmfmac4355*` from a GitHub branch at build time (t2-enablement.sh:56-57).
5. **Sleep is deliberately removed, twice**: `systemctl mask suspend.target` (t2-enablement-ublue.sh:69) plus a logind drop-in that ignores lid/suspend/hibernate keys (t2-lidswitch.conf:9-11, comment:2 "no suspend since it doesn't work on T2s"). README:47 jokes about "a laptop that can't suspend".
6. **Fingerprint is effectively absent on the Bluefin flavour**: `t2-touchid` is installed only by the fedora-bootc script (t2-enablement.sh:40); the UBlue script does not install it, and cdc_ncm/cdc_mbim are blacklisted specifically because "downstream devices aren't yet supported (Touch ID, etc)" (t2-eth-blocklist.conf:2-11).
7. **Touchbar has zero treatment** — no package, no daemon, no module reference, no config, anywhere in the tree.
8. **Secure Boot / module signing is not addressed at all**: no MOK, no key enrolment, no module signing, no shim handling; grep for `mokutil|sbctl|shim|pesign|kernel-sign|enroll` returns nothing. The only signing present is cosign on the container image (build-image-bluefin.yml:165-179, `cosign.pub`).
9. **Bluefin does not consume t2-atomic — the dependency is inverted.** `bluefin` and `akmods` trees contain **zero** t2/kansei references; `variants/t2-bluefin/Containerfile:7` is `FROM ghcr.io/ublue-os/bluefin:stable`. "Bluefin's T2 support" is a separate downstream image published by kansei-os, not something Bluefin builds or knows about.
10. Verdict up front: the **packaging mechanics are reusable and already proven** (kernel swap in-image, firmware placement, dracut forcing from an `/etc` drop-in, unit mask/enable at build, BIB ISO production, cosign). The **T2 capability layer is not reusable** for KaiT2en-Bluefin: it deletes Bluefin's akmods to install a foreign kernel, has no touchbar/fingerprint/sleep story, no signing story, and its build has real wiring bugs (a T2-Bluefin ISO that switches to the Silverblue image).

---

## 1. What it actually is

### 1.1 Build system: Containerfile + bootc, not blue-build

| Fact | Evidence |
|---|---|
| Multi-stage Containerfile, build scripts bind-mounted from a `scratch` stage so they never land in the image | `Containerfile:2-3` |
| Base is a bootc/OCI desktop image, one per variant | `Containerfile:6`; `variants/t2-bluefin/Containerfile:7`; `variants/t2-kinoite-hardened/Containerfile:6` |
| Single `RUN` invokes the shared script then `ostree container commit` | `Containerfile:21-26`; `variants/t2-bluefin/Containerfile:25-37` |
| Gate: `bootc container lint` in every variant | `Containerfile:30`; `variants/t2-bluefin/Containerfile:41` |
| bootc markers | `Containerfile:33-34` (`containers.bootc`, `ostree.bootable`) |
| No blue-build recipe (`recipe.yml`), no `bluebuild` CLI, no `recipes/` dir | full file list, `git ls-files` |

Local builds are `podman build` via `just build` (Justfile:89-101); bootable artifacts via BIB (`Justfile:161-188`).

### 1.2 The 12 variants and their bases (all evidence: first `FROM` after the ctx stage)

| Containerfile | Base image | Enablement script |
|---|---|---|
| `Containerfile` (unbranded `t2-atomic`) | `quay.io/fedora/fedora-bootc:42` (:6) | `t2-enablement.sh` (:25) |
| `variants/t2-bluefin/` | `ghcr.io/ublue-os/bluefin:stable` (:7) | `t2-enablement-ublue.sh` (:29) |
| `variants/t2-bluefin/dx/` | `ghcr.io/ublue-os/bluefin-dx:stable` | `t2-enablement-ublue.sh` |
| `variants/t2-bazzite/` | `ghcr.io/ublue-os/bazzite:stable` | `t2-enablement-ublue.sh` |
| `variants/t2-bazzite-gnome/` | `ghcr.io/ublue-os/bazzite-gnome:stable` | `t2-enablement-ublue.sh` |
| `variants/t2-aurora/` | `ghcr.io/ublue-os/aurora:stable` | `t2-enablement-ublue.sh` |
| `variants/t2-cosmic/` | `ghcr.io/ublue-os/base-main:44` | `t2-enablement.sh` |
| `variants/silverblue/` | `ghcr.io/ublue-os/silverblue-main:44` | `t2-enablement.sh` |
| `variants/t2-kinoite-hardened/` | `ghcr.io/secureblue/kinoite-main-hardened:latest` (:6) | `t2-enablement.sh` |
| `variants/kansei/` | `quay.io/fedora/fedora-silverblue:45` (:7) | `t2-enablement-ublue.sh` |
| `variants/kansei/44/` | `quay.io/fedora/fedora-silverblue:44` (:7) | `t2-enablement-ublue.sh` |
| `variants/kansei/falcon/` | `ghcr.io/ublue-os/bazzite-gnome-nvidia:stable` | `apps-*` + `ublue-packages.sh` (no T2 script — see §9.6) |

Note the two `kansei` variants build `FROM quay.io/fedora/fedora-silverblue:*` — an ostree *commit* namespace, not a bootc container. Whether that resolves is not verifiable from the tree.

### 1.3 Published image refs

Naming rule is `${{ github.event.repository.name }}-<suffix>`, registry `ghcr.io/${{ github.repository_owner }}` (build-image-bluefin.yml:20-21): `t2-atomic-{silverblue,bazzite,bazzite-gnome,cosmic,bluefin,bluefin-dx,aurora,centos,kansei,kinoite-hardened}` plus bare `t2-atomic` from the root Containerfile (build.yml:20,105). README:6-14 advertises 7 of them, omitting kansei/kinoite-hardened/centos.

### 1.4 Where Bluefin fits (the "how does Bluefin consume t2-atomic" answer)

It does not. Evidence:

- `grep -rin 'kansei'` over `research/bluefin` and `research/akmods` → **no matches**.
- `grep -rin 't2'` over `research/bluefin` → one false positive (`bluefin/build_files/base/04-packages.sh:73`, `python3-pygit2`). Over `research/akmods` → **no matches**.
- The only edge is one-directional: `variants/t2-bluefin/Containerfile:7` `FROM ghcr.io/ublue-os/bluefin:stable`.

So today's "thin T2 support in Bluefin" is **a kansei-os derived image that rebases Bluefin**, rebuilt daily off a floating `stable` tag (bluefin workflow cron `30 10 * * *`, build-image-bluefin.yml:7-8) with no digest pinning and no coordination with Bluefin's own build.

---

## 2. Kernel strategy

### 2.1 Mechanism

```sh
rpm-ostree cliwrap install-to-root / && \
  rpm-ostree override replace --experimental --freeze \
  --from repo=copr:copr.fedorainfracloud.org:sharpenedblade:t2linux \
  kernel-uki-virt kernel kernel-core kernel-modules kernel-modules-core \
  kernel-modules-extra kernel-devel kernel-devel-matched kernel-tools kernel-tools-libs
```
`t2-enablement-ublue.sh:34-42` (the fedora-bootc variant is the same list minus `kernel-uki-virt`/`kernel-tools*`, `t2-enablement.sh:32-39`).

Supporting steps, in order:
1. `dnf5 -y copr enable sharpenedblade/t2linux` (`t2-enablement-ublue.sh:21`; the fedora-bootc path pins a chroot, `t2-enablement.sh:21-22`).
2. **Rip out the base's out-of-tree kernel modules**: `dnf5 -y remove kmod-framework-laptop kmod-openrazer kmod-xone kernel-modules-akmods kmod-v4l2loopback kernel-headers` (`t2-enablement-ublue.sh:22-25`).
3. Force ostree kernel layout for image builds if absent: append `layout=ostree` to `/usr/lib/kernel/install.conf` (`t2-enablement-ublue.sh:29-31`, `t2-enablement.sh:27-29`).
4. Override+freeze (§2.1 above).
5. `dnf5 -y copr disable sharpenedblade/t2linux` so the COPR is not live in the shipped image (`t2-enablement-ublue.sh:50`).

**No akmods. No DKMS. No kernel patch series.** `grep -ri dkms .` → 0 matches; `grep -ri mok|sign` → only cosign. All T2 kernel code is whatever the COPR kernel RPM contains; the repo never lists it.

### 2.2 How it survives kernel updates

Update model is **rebuild-the-image, not rebuild-the-modules**: workflows run on cron (e.g. `build-image-bluefin.yml:7-8`) against a floating `ghcr.io/ublue-os/bluefin:stable`, so base, kernel and T2 modules move together in one OCI commit; the user gets them as an ordinary bootc update. There is **no** in-image mechanism that rebuilds modules against a newly-installed host kernel (nothing DKMS/akmods-shaped exists), so a kernel arriving by any path other than a new image would leave modules behind.

Two frictions the tree itself admits:
- `--freeze` pins the override, so a base image whose kernel moves ahead cannot silently win — but the repo never says what happens on conflict.
- README:40 states the older **rpm-ostree override method "has been deprecated, and does appear to no longer work as of June 2025"**, yet the current scripts still use exactly that command (`t2-enablement-ublue.sh:34-42`). The `--freeze` flag is the likely difference; the tree does not explain the contradiction.

### 2.3 Secure Boot / module signing

**Not stated in tree.** Nothing in the repo addresses:
- MOK enrolment or a signing key for the COPR kernel/modules;
- `akmods`-style out-of-tree signing (the `akmods` packages are *removed*, `t2-enablement-ublue.sh:24`);
- shim, `pesign`, `sbctl`, kernel signature verification.

The only signing that exists is artifact signing: `cosign sign -y --key env://COSIGN_PRIVATE_KEY` over pushed tags (build-image-bluefin.yml:165-179) with the public key committed (`cosign.pub:1-4`). That authenticates the image, not the kernel.

### 2.4 initramfs / dracut

- Early-boot input is forced by an image-shipped dracut drop-in: `force_drivers+=" t2bce_dma t2bce_core t2bce_vhci "` with the comment "load t2bce early so keyboard works for LUKS and early boot" (`variants/common/etc/dracut.conf.d/t2-bce.conf:1-2`).
- **Ordering is load-bearing and documented**: the drop-ins are `COPY`d before the RUN that installs the kernel (`variants/t2-bluefin/Containerfile:23` before `:25`), and the hardened variant says so explicitly: "Must be added before T2 kernel install so dracut includes it in the initramfs" (`variants/t2-kinoite-hardened/Containerfile:24-25`).
- An explicit `dracut --no-hostonly ... --add ostree` regeneration exists but is **commented out** in both live scripts (`t2-enablement-ublue.sh:78-83`, `t2-enablement.sh:69-74`), i.e. the design relies on kernel-install-time dracut in the container build. It remains active only in the unused legacy script (`t2-enablement-dnf4.sh:66-69`).

---

## 3. Module / app coverage

**Delegation warning:** the repo installs three T2 packages and a kernel; it never enumerates what they contain. Anything below marked *delegated* is not stated in tree and must be verified against the COPR spec/kernel, not against this repo.

| Component | Status in t2-atomic | Mechanism | file:line |
|---|---|---|---|
| Kernel (T2-patched) | provided, foreign | `rpm-ostree override replace --experimental --freeze` from COPR | t2-enablement-ublue.sh:34-42 |
| T2 BCE stack (internal USB: keyboard, trackpad, ethernet, Touch ID transport) | **delegated to COPR kernel** | modules `t2bce_dma/_core/_vhci` only referenced by name in a dracut drop-in | t2-bce.conf:1-2 |
| Keyboard (internal, incl. LUKS unlock) | provided via BCE + dracut forcing | `force_drivers` | t2-bce.conf:2; ordering t2-kinoite-hardened Containerfile:24-25 |
| Trackpad | provided (kernel module, delegated); no T2-specific userspace | HID via BCE in the COPR kernel; `libinput`, `libinput-utils` installed | t2-enablement-ublue.sh:55 |
| Touchbar | **absent** | zero references in tree (no pkg, daemon, module, config) | n/a |
| Audio (speakers/mic) | **delegated / not stated** (kernel + userspace both from COPR) | `t2linux-release` metapackage only; `t2linux-audio` appears **only** in the unused legacy script; one PipeWire tweak (`rm raop.conf`) | t2-enablement-ublue.sh:44,45; t2-enablement-dnf4.sh:36 |
| Camera | **absent** | no package, no config, no mention | n/a |
| Fingerprint / Touch ID | **absent on Bluefin flavour; gated off** | `t2-touchid` installed only in fedora-bootc script; `blacklist cdc_ncm`/`cdc_mbim` blocks the T2 internal USB path with comment "Touch ID, etc" | t2-enablement.sh:40 vs t2-enablement-ublue.sh:44; t2-eth-blocklist.conf:2-11 |
| Wi-Fi (brcmfmac) | firmware **baked**; driver = kernel module from COPR kernel | `tar -xf radio.tar -C /lib/firmware/brcm`; plus 4355 fetch in one variant | t2-enablement-ublue.sh:65-66; t2-enablement.sh:56-57 |
| Wi-Fi stack | switched to iwd | `dnf5 swap wpa_supplicant iwd` + NM `wifi.backend=iwd` | t2-enablement-ublue.sh:59-63 (only in the -ublue script) |
| Bluetooth (brcmbt) | firmware **baked**; stack default | same tar; `ControllerMode = bredr` override | t2-enablement-ublue.sh:65-66; bluetooth/main.conf:52 |
| GPU / gmux | **config stub only** | `options apple-gmux force_igd=y` is commented out; `radeontop` installed | apple-gmux.conf:5; t2-enablement-ublue.sh:55 |
| SMC / fans | userspace daemon (no kernel-side control app) | `t2fanrd` installed + `systemctl enable t2fanrd.service` | t2-enablement-ublue.sh:44,70 |
| Sensors | userspace | `lm_sensors` | t2-enablement-ublue.sh:55 |
| Sleep / suspend | **explicitly disabled** | `systemctl mask suspend.target`; logind ignores lid/suspend key | t2-enablement-ublue.sh:69; t2-lidswitch.conf:2,9-11 |
| Hibernate | **explicitly disabled** | `HandleHibernateKey=ignore`, long-press→poweroff | t2-lidswitch.conf:7-8 |
| Thunderbolt | not stated | no package/config | n/a |
| Internal Ethernet (T2 NCM) | **deliberately blocked** | `blacklist cdc_ncm`, `blacklist cdc_mbim` | t2-eth-blocklist.conf:10-11 |
| Optical drive (SuperDrive) | userspace | `sg3_utils`, `wodim`, `xorriso` | t2-enablement-ublue.sh:52-55 |
| fwupd / firmware updates | neutralised | capsules plugin disabled ("Macs don't support the UEFI capsule update interface") | fwupd.conf:4-7 |
| Secure Boot | **absent** | nothing in tree | n/a |
| Update delivery | supplied | bootc/OCI, cosign-signed, daily cron | build-image-bluefin.yml:7-8,165-179 |

---

## 4. Firmware

Two mechanisms, both **baked into the image at build time** (not downloaded on the machine, not a sysext yet):

1. **`radio.tar` → `/lib/firmware/brcm`** (`t2-enablement-ublue.sh:65-66`, `t2-enablement.sh:53-54`, `t2-enablement-dnf4.sh:51-52`). The tarball is committed to git (`git ls-files` includes it), 12,185,600 B, 163 entries, flat (no directory prefix), mtimes all 1970-01-01, 0/0 ownership. Contents by chip family:

   | Family | Files | Kinds |
   |---|---|---|
   | brcmfmac4364b2 | 72 | `.bin`, `.clm_blob`, `.txcap_blob`, per-board `-HRPN-{m,u}-<ver>.txt` |
   | brcmfmac4364b3 | 36 | same shape (bali/borneo/…) |
   | brcmfmac4377b3 | 15 | same shape |
   | brcmbt4378b1 | 20 | `.bin` + `.ptb` (atlantisb, capri, honshu, santorini, shikoku) |
   | brcmbt4387c2 | 10 | hokkaido, madagascar, maldives, okinawa, snake |
   | brcmbt4378b3 / 4377b3 / 4388b0 / 4388c0 / 4388c2 | 2 each | kyushu-u, formosa, willamette-u |

   **`brcmfmac4355` is not in the tarball** (grep count 0) — see §9.2.
2. **Unpinned network fetch, one variant only:** `curl -sL https://github.com/AdityaGarg8/Apple-Firmware/archive/refs/heads/main.tar.gz | tar xz --strip-components=4 -C /lib/firmware/brcm --wildcards '*/brcmfmac4355*'` (`t2-enablement.sh:56-57`). No checksum, no commit pin, build-time network dependency.

Nothing records provenance, licence or update policy for `radio.tar`; README:25 lists a systemd-sysext firmware delivery as *upcoming* ("will allow more flexibility for those who may not want to run more proprietary code"), i.e. the current state is "proprietary blobs baked into the OS image".

Also culled: several Fedora firmware packages are removed as Mac-irrelevant (`tiwilink`, `nxpwireless`, `nvidia-gpu`, `mt7xxx`, `iwlegacy`, `iwlwifi-dvm/mvm`, `qcom-wwan`) — `t2-enablement-ublue.sh:48-49`, `t2-enablement.sh:44-45`.

---

## 5. Installation / rebase flow

**Published flow (README:5-14, MIGRATION.md:7-23):**
1. Install a stock Bazzite/Bluefin/Silverblue ISO **with external keyboard + mouse** (and keep them for the LUKS passphrase) — README:4-5, 38.
2. `sudo bootc switch ghcr.io/kansei-os/t2-atomic-<variant>:latest` (README:6-13; MIGRATION.md:13-17).
3. Reboot; `rpm-ostree db diff` to inspect the transaction (MIGRATION.md:20); pin the old deployment first with `sudo ostree admin pin 0` (MIGRATION.md:8); roll back from the boot menu (MIGRATION.md:23).
4. No documented post-install steps beyond the reboot. First boot is claimed to bring "the t2linux kernel, wifi/bt firmware, and other essential tooling" (README:4).

**ISO path (aspirational or broken — see §9.5):** BIB builds an Anaconda ISO from the variant image (`Justfile:161-188`, `build-iso-bluefin.yml:82-89`), whose kickstart does `bootc switch --mutate-in-place --transport registry ghcr.io/kansei-os/t2-atomic-bluefin:latest` in `%post` (`disk_config/iso-bluefin.toml:4`), with Anaconda modules Network/Security/Services/Subscription/Timezone disabled (`iso-bluefin.toml:14-18`).

---

## 6. Known limitations, as documented in the tree

| Claim | Where |
|---|---|
| Alpha state, "not ready for public consumption" | README:3, 34 |
| Installer cannot run the T2 kernel → external keyboard/mouse required; internal keyboard unusable for the LUKS passphrase until T2 kernel is installed | README:4, 5, 38, 40 |
| "missing some rather critical components like wifi/bluetooth firmware" — **contradicted by the code**, which bakes it (README reflects an earlier state, or refers to the unbranded image) | README:34 vs t2-enablement-ublue.sh:65-66 |
| Sleep does not work; suspend is masked, lid is a no-op, "just reboot daily ... a laptop that can't suspend" | t2-lidswitch.conf:2,9-11; t2-enablement-ublue.sh:69; README:47 |
| Hibernate does not work | t2-lidswitch.conf:7-8 |
| Touch ID not supported (comment, as of blocklist v4 "starting to be supported, may need to adjust this list") | t2-eth-blocklist.conf:2-6 |
| rpm-ostree kernel-override method deprecated / "no longer work as of June 2025" | README:40 |
| Only one test machine named: MacBookPro15,2 (2018 13" 4-port) | README:34 |
| No issue templates, no docs dir, no model-support matrix in-tree (wiki is external) | `.github/` holds only `dependabot.yml`, `renovate.json5`, `workflows/`; README:19 points to a wiki |
| **No touchbar statement at all** — the gap is silence, not a documented limitation | n/a |

---

## 7. What t2-atomic proves about the immutable-OS T2 problem

This is the reusable part. Each mechanic is demonstrated in a file, independent of whether its T2 content is good enough.

| # | Mechanic proven | Evidence |
|---|---|---|
| M1 | **A foreign kernel + its module tree can be installed into an OCI/bootc image at build time**, atomically with the rest of the image, and committed as one deployment | t2-enablement-ublue.sh:34-42; Containerfile:25-26 |
| M2 | **The base's out-of-tree-module machinery actively conflicts** with that kernel swap, and must be removed first (`kernel-modules-akmods`, `kernel-headers`, `kmod-*`) | t2-enablement-ublue.sh:22-25 |
| M3 | **Initramfs content can be steered from an image-shipped `/etc/dracut.conf.d` drop-in**, provided the drop-in is COPIED before the kernel RPM runs kernel-install | t2-bce.conf:1-2; t2-bluefin Containerfile:23 before :25; t2-kinoite-hardened Containerfile:24-25 |
| M4 | **Firmware can be baked as plain files** into the image build and is then part of the signed OCI commit (no first-boot network, no /var mutation) | t2-enablement-ublue.sh:65-66 |
| M5 | **systemd units can be enabled and masked at build time** and the result survives updates (`systemctl enable t2fanrd`, `systemctl mask suspend.target`) | t2-enablement-ublue.sh:69-70 |
| M6 | **Behavioural policy ships as `/etc` drop-ins** alongside the kernel: logind lid policy, modprobe blacklists, BlueZ controller mode, fwupd plugin disable | t2-bluefin Containerfile:23; t2-lidswitch.conf; t2-eth-blocklist.conf; bluetooth/main.conf:52; fwupd.conf:7 |
| M7 | **A bootable installer artifact can be produced from the same container image** by BIB, and the install can be turned into a `bootc switch` in `%post` — while the installer environment itself still cannot drive T2 input | Justfile:161-188; build-iso-bluefin.yml:82-89; iso-bluefin.toml:4; README:4 |
| M8 | **The whole matrix is one shared script set**: 12 Containerfiles differ only in base image + script selection, so N desktop flavours cost ~10 lines each | variants/*/Containerfile |
| M9 | **Image-level signing + provenance is cheap**: cosign over tags, pubkey in repo, ArtifactHub metadata, `bootc container lint` gate | build-image-bluefin.yml:165-179; cosign.pub; Containerfile:30 |
| M10 | **Rollback is the safety net for hardware risk**: pin the old deployment, switch, `rpm-ostree db diff`, boot-menu rollback | MIGRATION.md:8,20,23 |
| M11 | **A third-party COPR is a workable supply chain for a kernel**, and can be disabled in the shipped image so it is not a live repo on the user's machine | t2-enablement-ublue.sh:21,50 |

---

## 8. Gaps vs KaiT2en (the reason for the exercise)

Comparison basis, all cited from `research/KaiT2en-Fedora`: modules are DKMS (`README.md:4`) covering `t2bce_core/_dma/_vhci/_audio/_stack`, `t2bdrm`, `t2touchbar`, `t2_precision_trackpad`, `t2_trackpad_actuator`, `t2smc`, `t2smp`, `t2sbs`, `t2sep`, `t2gmux`, `t2mfi_fastcharge`, `t2thunderbolt`, `hid_t2magicmouse` (`modules/` listing); userspace features are separate packages `t2-touchid`, `t2-ave`, `t2-journal` (`t2-services/README.md:5-13`); touchbar has an app + install/uninstall flow (`apps/t2-touchbar/install.sh`); suspend/resume hooks exist (`t2-services/README.md:44-52`, `t2-services/shared/integration/systemd/t2-services-suspend.service`); firmware install is model-aware (`auto-installer/README.md:1-55`).

| Gap | t2-atomic | KaiT2en | Consequence for KaiT2en-Bluefin |
|---|---|---|---|
| **Sleep / resume** | Masked twice; lid ignored; "doesn't work on T2s" (t2-enablement-ublue.sh:69; t2-lidswitch.conf:2,9-11) | Suspend service + `t2bce_vhci` reset-resume of the NCM link (t2-services/README.md:44-52) | Must **unmask and re-implement**, not port: t2-atomic's config *is* the regression. This is the single biggest behavioural difference. |
| **Fingerprint / Touch ID** | Package present only on fedora-bootc flavour (t2-enablement.sh:40); the ROUTE it needs is blacklisted on all variants (t2-eth-blocklist.conf:2-11) | `t2-touchid` service + fprintd integration over the internal CDC-NCM link (t2-services/README.md:5-13, 44-52) | Must **invert the blocklist**: t2-atomic disables `cdc_ncm`/`cdc_mbim`; KaiT2en's Touch ID depends on that link. Direct file-level conflict. |
| **Touchbar** | Nothing (no refs) | `t2touchbar` module + `t2-touchbar` app with firmware-row fallback (apps/t2-touchbar/README.md, install.sh) | Entirely **new work**; no precedent in t2-atomic to reuse. |
| **Audio** | `t2linux-release` metapackage; `t2linux-audio` only in the dead legacy script (t2-enablement-dnf4.sh:36); one PipeWire tweak | `t2bce_audio` module + ALSA UCM profiles + DSP profiles (`modules/t2bce_audio-alsa-ucm-conf`, README:45) | Must **come from KaiT2en**; t2-atomic's bluefin path has no audio enablement it can lend. |
| **Camera** | Absent | Not established here (task-1) | New work. |
| **Wi-Fi/BT on older models** | 4355 firmware absent from the tarball and fetched only in the fedora-bootc variant (t2-enablement.sh:56-57 vs t2-enablement-ublue.sh:65-66) | model-aware firmware install (auto-installer/README.md:49-55) | The fedora-bootc path deliberately pulls `brcmfmac4355*`, so some supported models need it; the Bluefin path drops it. **BCM4355 Macs lose Wi-Fi on the Bluefin image**, while KaiT2en already does per-model firmware. |
| **Fan/SMC control** | `t2fanrd` only | `t2smc`, apps for fan/power/charge (`apps/t2-fan-control`, `t2-power-*`, `t2-smc-control`) | t2-atomic gives a daemon; KaiT2en gives control surfaces. |
| **Module provenance** | Opaque COPR kernel (nothing enumerated) | In-repo module sources + DKMS conf per module | t2-atomic **cannot** be the module source; it can only be a packaging pattern. |
| **Secure Boot** | Absent | Not established here | Must be solved fresh (§2.3). |

---

## 9. Defects and hazards found in the tree (do not copy these)

1. **Unpinned firmware download** — `curl …/refs/heads/main.tar.gz` with no checksum/commit (t2-enablement.sh:56-57). Non-reproducible, supply-chain exposed.
2. **Wi-Fi regression for BCM4355 Macs in the Bluefin path** — the `-ublue` script extracts only `radio.tar`, which has no 4355 firmware (t2-enablement-ublue.sh:65-66; tar inventory §4).
3. **Feature asymmetry nobody documents** — `t2-touchid`, `brcmfmac4355`, and explicit `dracut` regeneration exist only in `t2-enablement.sh` (fedora-bootc), not in the `-ublue` script that builds the Bluefin image (t2-enablement.sh:40,56-57,69-74 vs t2-enablement-ublue.sh:44,65-66,78-83).
4. **The unbranded `t2-atomic` image gets no `/etc` drop-ins at all** — root `Containerfile` never COPYs `variants/common/etc`, so it ships without the dracut early-keyboard drop-in, lid policy, cdc_ncm blocklist, BlueZ mode or fwupd fix (Containerfile:1-34 vs variant Containerfile:23).
5. **The ISO wiring is wrong: every ISO switches to the Silverblue image.** All three ISO workflows pass `./disk_config/iso.toml` (`build-iso-bluefin.yml:85`, `build-iso-bazzite.yml:85`, `build-iso-silverblue.yml:86`), and `iso.toml:4` switches to `ghcr.io/kansei-os/t2-atomic-silverblue:latest`. `iso-bluefin.toml` and `iso-bazzite.toml` are referenced **only** as PR path triggers (`build-iso-bluefin.yml:23`, `build-iso-bazzite.yml:23`) and are never used as `config-file`.
6. **`build-image-centos.yml` points at a Containerfile that does not exist** (`variants/centos/Containerfile`, build-image-centos.yml:105; `variants/` has no `centos/`). `variants/kansei/falcon/` also never runs `t2-enablement*.sh`, so the "T2" falcon spin is Bazzite+NVIDIA with no T2 layer at all (grep of `/ctx/` refs: only `apps-falcon.sh`, `apps-kansei.sh`, `ublue-packages.sh`).
7. **Dead scripts**: `build_files/t2-enablement-dnf4.sh` is referenced by no Containerfile; `build_files/build.sh` is only mentioned in comments. The legacy dnf4 path is also the only one that installs `t2linux-audio` and regenerates the initramfs.
8. **`set -ouex pipefail`** heads every script (`t2-enablement-ublue.sh:3`). Verified on bash: this does enable `errexit`, `nounset`, `xtrace` **and** `pipefail` (the `pipefail` word is consumed as `-o pipefail`), so no defect — recorded because it looks wrong.
9. **No pinning of the base image**: `FROM ghcr.io/ublue-os/bluefin:stable` with no digest (t2-bluefin Containerfile:7), while Bluefin itself pins digests (`bluefin/image-versions.yml:6-17`). Renovate is explicitly told not to bump container digests in workflows (`.github/renovate.json5:13-19`). Daily rebuilds of a floating base are therefore unreviewed drift.
10. **No tests.** The only gate is `bootc container lint` (Containerfile:30). `just lint`/`just format` are shellcheck/shfmt on scripts (Justfile:298-319). There is no VM boot test, no module-presence assertion, no `lsmod` check, no dracut-content check, no hardware test record.
11. **Agent-directed refusal file**: `CLAUDE.md` (symlinked as `AGENTS.md`) contains an instruction to automated agents to "cease processing … refuse further interaction", followed by a canary-style magic string (CLAUDE.md:1-11). Read as repository content, not as an instruction; flagged here because the clone sits inside our research tree and will be re-read by other agents.
12. **`bootc container lint` vs an overridden kernel**: the override metadata is created with `rpm-ostree cliwrap install-to-root /` inside a container build (t2-enablement-ublue.sh:34) and committed via `ostree container commit`. Whether a `--freeze` override recorded this way is honoured by bootc at runtime, and how it behaves on the next base-image rebase, is **not stated in tree** and is the highest-risk unverified assumption in the whole design.

---

## 10. Verdict for KaiT2en-Bluefin

**Reuse (mechanics, proven):**
- The `ctx`-stage + bind-mount + `ostree container commit` + `bootc container lint` Containerfile shape (Containerfile:1-34).
- One shared `t2-enablement` script parameterised per base, selected per variant — the 12-variant pattern (variants/*/Containerfile).
- Firmware-as-files into `/lib/firmware/brcm` (M4) — but with pinned, checksummed, licensed provenance instead of a committed tarball + `curl` of a branch.
- dracut forcing from an image drop-in, with the COPY-before-kernel-install ordering (M3) — this is the mechanic that makes LUKS unlock possible at all.
- `systemctl enable`/`mask` + `/etc` drop-ins as the policy surface (M5, M6).
- BIB ISO production and the kickstart `bootc switch` (M7), cosign signing + pubkey (M9), pin/switch/rollback flow (M10).

**Replace (capability + supply chain):**
- The kernel: a `sharpenedblade/t2linux` COPR kernel is a different module set from KaiT2en's in-repo modules, and it forces the **destruction of Bluefin's akmods machinery** (M2, t2-enablement-ublue.sh:22-25). Bluefin's akmods path is the thing that already knows how to build and sign out-of-tree modules per kernel *inside the image*, which is much closer to what KaiT2en needs. t2-atomic's answer (delete akmods, take a foreign kernel) is the wrong trade for a KaiT2en carrier; the open question the design must answer is whether KaiT2en's 17 module trees become akmods (per-kernel RPMs in the image) or a self-built kernel.
- The `/etc` policy set: `t2-lidswitch.conf` (no suspend) and `t2-eth-blocklist.conf` (no cdc_ncm) are the **opposite** of what KaiT2en needs — they must be replaced, not inherited.
- The firmware acquisition, the ISO wiring (§9.5), the centos/falcon breakage (§9.6), the dead legacy script, and the absence of any test gate.

**Not available from t2-atomic at all:** touchbar, fingerprint/Touch ID on the Bluefin flavour, working sleep, audio enablement, camera, SMC/power control surfaces, secure-boot/module-signing story, BCM4355 Wi-Fi in the Bluefin path.

---

## 11. Explicitly not in the tree

Recorded so the design does not inherit invented facts: no `recipe.yml`/blue-build tooling; no DKMS; no akmods build; no MOK/signing/enrolment; no touchbar anything; no camera anything; no hibernate config beyond "ignore"; no model/firmware compatibility matrix (README:19 defers to an external wiki); no issue templates or docs directory; no test suite; no kernel patch series; no explanation of what `t2linux-release` pulls in; no statement of what happens when the base kernel outruns the COPR kernel; no licence/provenance for `radio.tar`; no git history (shallow, 1 commit).
