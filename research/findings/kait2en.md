# KaiT2en-Fedora — source inventory and immutable-image portability

Source analysed: `/home/matt/src/KaiT2en-Bluefin/research/KaiT2en-Fedora` (shallow clone, 840 files).
All citations are `path:line` relative to that root unless stated otherwise.

## Executive summary

1. KaiT2en-Fedora is **not a distro and not a remix**: it keeps Fedora's stock kernel and adds 12 DKMS source
   packages (18 `.ko` files), one non-DKMS patched `amdgpu`, ~30 packages from Fedora/RPM Fusion, and a large
   userspace layer concentrated in `/usr/local` (`scripts/fedora/install-dkms-modules.sh:11-24`,
   `scripts/fedora/install.sh:61-78`).
2. The whole system is a **mutable-host, runtime-compile design**: `dnf` at install time, `dkms build/install`
   against the *running* kernel, `grubby` on the live bootloader, `systemctl enable` into `/etc/systemd/system`,
   and `dracut --force /boot/initramfs-<kver>.img` (`install-dkms-modules.sh:258-263`,
   `install-kernel-args.sh:133-135`, `rebuild-initramfs.sh:26`).
3. The macOS-side kit modifies **only the EFI System Partition of a stock Fedora ISO** — it never rebuilds the
   ISO. It overwrites `EFI/BOOT/grub.cfg` and adds three files under `EFI/BOOT/kait2en/`
   (`scripts/macos/prepare-fedora-installer.sh:652-676`).
4. Live-system input support is a **custom initramfs with five out-of-tree modules built against the ISO's exact
   kernel** (`auto-installer/build-input-kmod.sh:55-57`, `auto-installer/kmod-kait2en-input.spec:34-44`), added
   as a second/third `initrd` line in GRUB (`auto-installer/grub.cfg.in:14`).
5. Apple firmware is **captured from the running macOS**, not from EFI and not from `/usr/lib/firmware`:
   `ioreg` `RequestedFiles` → `/usr/share/firmware/wifi/{*.trx,*.clmb,*.txcb,P-*.txt}` and, on BCM4377 only,
   `/usr/share/firmware/bluetooth/BCM4377*.{bin,ptb}` (`prepare-fedora-installer.sh:152-213`).
6. It is carried to the installed system in two hops: cpio→ESP (`kait2en-wifi-initramfs.img`) → dracut pre-pivot
   copies to `/run/kait2en/apple-firmware` → Anaconda addon renames and installs to
   `/usr/lib/firmware/brcm/brcmfmac*-pcie.apple,<board>*` and `brcmbt4377*-apple,<board>[-m|-u].{bin,ptb}`
   (`90-kait2en-updates.sh:18-20`, `installation.py:26-60,63-148`, `install-wifi-firmware.sh:136-145`).
7. Firmware is **per-machine and non-redistributable**; the project explicitly refuses the third-party
   redistribution packages `apple-bcm-firmware`/`apple-firmware`/`t2-apple-firmware`
   (`scripts/fedora/deprecated/brcm_fw.sh:69-101`).
8. Kernel policy: **no custom kernel**. Minimum is Linux **7.0** (`scripts/fedora/lib.sh:177-191`) and the
   installer *force-upgrades Fedora* to reach it with `dnf upgrade --refresh -y --setopt=installonly_limit=0`
   (`auto-installer/runtime/kait2en-prepare:227`).
9. **Nothing is signed.** There is no MOK, no `sign-file`, no akmods anywhere in the tree; the USB kit instead
   instructs the user to set Secure Boot to "No Security" (`prepare-fedora-installer.sh:87-102`).
10. The three things that hurt most on an immutable image: (a) DKMS-per-kernel compilation into `/usr/lib/modules`,
    (b) `dnf` + `grubby` + `dracut` manipulation of `/boot` and the deployment, (c) DMI-gated install decisions
    taken on a build host that is not the target Mac.

---

## 1. Repository layout, and what is load-bearing

| Path | Files | Purpose | Load-bearing? |
|---|---|---|---|
| `modules/` | 106 | 19 module source trees, each with `dkms.conf`; `t2bce_stack` is an aggregate that builds 5 `.ko` from 5 subdirs (`modules/t2bce_stack/Makefile:1-5`). `t2bce_audio-alsa-ucm-conf/` is data, not a module. | **Yes** — all kernel functionality |
| `apps/` | 198 | 11 Rust/GTK4 user apps + `install.sh`/`Makefile` per app; `deprecated/t2-cpu-control` is retired (`scripts/fedora/install-apps.sh:39-72`). | Yes for UX; optional for boot |
| `t2-services/` | 165 | `shared/` (NCM link + suspend hooks), `t2-ave/` (A VE HEVC service, also hosts `kernel/t2bce_ave`), `t2-touchid/` (fprintd bridge + SELinux policy), `t2-journal/` (BridgeOS log reader) | Yes (`t2bce_ave` is built into `t2bce_stack`, `install-dkms-modules.sh:222-242`) |
| `dsp/` | 91 | Model-specific PipeWire/WirePlumber speaker DSP graphs, generator, tests, RPM/Debian recipes | Yes for audio quality |
| `packaging/` | 6 | `installer/runtime/kait2en-install` (packaged copy), `lifecycle/kait2en-lifecycle.py` + tests | Yes (`lifecycle.py` is installed by 3 components) |
| `patches/` | 77 | `runtime/` (only dir scripts may consume, `patches/README.md:9-12`), `currently-testing/`, `upstream/`, `archived/` | **Yes** — `patches/runtime/gpu-runtime-pm/series` drives an 11-patch out-of-tree `amdgpu` |
| `scripts/` | 60 | `fedora/` (installer), `macos/` (USB kit), `copr/` (kernel experiments), `ci/`, `tests/` | **Yes** |
| `assets/` | 23 | fonts, GDM dconf/branding, Plymouth theme, logos | Cosmetic |
| `auto-installer/` | 32 | The USB installer kit: Anaconda addon, input-kmod builder, initramfs hooks, live helpers, target configs | **Yes** — this is the only install path that works on a bare T2 Mac |
| `website/` | 59 | Docs and blog. `website/docs/reference/installed-files.md` is an authoritative inventory and cross-checks the code. | No (documentation) |
| `third-party/`, `.github/` | 15 | notices; CI (`installer.yml`, `kernel-copr.yml`, `pages.yml`, discord sync) | CI yes |

There is **no `/opt` write anywhere** in the tree. There is no `akmods`, no `.spec` for the T2 modules (only
`auto-installer/kmod-kait2en-input.spec`, an installer-transition package), and no MOK/signing code.

---

## 2. Installer entrypoints and the complete mutation inventory

### 2.1 Entry points

| Entry | Role |
|---|---|
| `scripts/macos/prepare-fedora-installer.sh` | Runs on macOS. Downloads/verifies a Fedora ISO, writes it to USB, captures firmware, injects the input initramfs + firmware initramfs + GRUB config (`:33-47` usage, `:608-681` the actual writes). |
| `auto-installer/runtime/kait2en-install` | Post-install guided installer (phase 1/2), two-boot flow (`:191-224`). |
| `auto-installer/runtime/kait2en-prepare` | Phase 1: upgrades Fedora, builds a transition kmod for the *next* kernel, injects it into that kernel's initramfs, sets it default (`:226-298`). |
| `scripts/fedora/install.sh` | The real installer. Runs 16 steps (`:61-78`); can be re-run any time. |
| `packaging/installer/runtime/kait2en-install` | Packaged copy of the same script (not separately analysed; byte-identical role). |

`install.sh` preflight: root, repo layout, `ID=fedora`, kernel ≥ 7.0 (`:5-8`, `lib.sh:177-191`), then an
interactive Touch Bar question gated on DMI `MacBookPro15,*|16,*` (`install.sh:13-51`, `lib.sh:128-133`).

### 2.2 Repositories added

* **RPM Fusion free + non-free** — installed from URL RPMs, only by the *optional* video-decode script:
  `install-hardware-video-decoding.sh:31-46` (`dnf install -y https://mirrors.rpmfusion.org/$repo/fedora/rpmfusion-$repo-release-$fedora_version.noarch.rpm`).
* **COPR** — never at install time. Kernel experiments are built in COPR by CI (`scripts/copr/README.md:32-38`,
  `.github/workflows/kernel-copr.yml`), i.e. a *separate* opt-in channel, not part of the product install.
* No third-party repo is added by `scripts/fedora/install.sh` or by any of its 16 steps.

Note: `install-hardware-video-decoding.sh` is **not** in the `STEPS` array (`install.sh:61-78`) and has **no
caller in the tree**; it is a documented manual step (`website/docs/post-install/hardware-video-decoding.md:20`).

### 2.3 Packages installed (exact)

`install-dependencies.sh:24-54`, one `dnf install -y` per package in a loop (`:57-62`):

```
plymouth-plugin-script acpica-tools alsa-ucm dkms gcc gcc-c++ make python3 python3-gobject
pkgconf-pkg-config kernel-devel-$KVER kernel-headers elfutils-libelf-devel dracut grubby
polkit cargo rust gtk4-devel libadwaita-devel glib2-devel libinput-devel libplist-devel
systemd-devel fprintd fprintd-pam libfprint checkpolicy policycoreutils-python-utils
```

`kernel-devel-$KVER` is only used when the running kernel looks like `*.fc*.x86_64`; otherwise a custom build
tree under `/lib/modules/$KVER/build` is required (`:10-21`).

Further install-time `dnf` calls:

| Call | Site |
|---|---|
| `pipewire pipewire-pulseaudio 'wireplumber >= 0.5.8' pipewire-module-filter-chain-lv2 lv2-bankstown lsp-plugins-lv2` | `install-dsp.sh:33-35` |
| `kernel-devel-$KVER cpio curl elfutils-libelf-devel gcc git-core make patch tar xz` | `install-gpu-runtime-pm.sh:202-212` |
| `adwaita-sans-fonts cargo gcc libinput-devel make pkgconf-pkg-config rust systemd-devel` (Touch Bar only) | `apps/t2-touchbar/install.sh:57` |
| `git` (phase 1 bootstrap) | `kait2en-prepare:137` |
| `cpio rpm-build` (phase 1) | `kait2en-prepare:249` |
| `dnf upgrade --refresh -y --setopt=installonly_limit=0` (whole-system upgrade) | `kait2en-prepare:227` |
| RPM Fusion + `libva-utils` + `mesa-va-drivers-freeworld`/`intel-media-driver` swap | `install-hardware-video-decoding.sh:44,65,67,114-115` |

### 2.4 DKMS modules built

`install-dkms-modules.sh:11-24` — installed for the **running** kernel (`dkms build/install` without `-k`,
`:262-263`):

| DKMS package | Version | Modules produced | Source |
|---|---|---|---|
| `t2bce_stack` | 0.01 | `t2bce_dma`, `t2bce_core`, `t2bce_vhci`, `t2bce_audio`, `t2bce_ave` | `modules/t2bce_stack/dkms.conf:1-24`; sub-sources staged from `modules/t2bce_{dma,core,vhci,audio}` and `t2-services/t2-ave/kernel/t2bce_ave` (`install-dkms-modules.sh:222-242`) |
| `t2smc` | 0.1 | `t2smc` | `modules/t2smc/dkms.conf:1-9` |
| `t2bdrm` | 0.1 | `t2bdrm` | `modules/t2bdrm/dkms.conf` |
| `t2touchbar` | 0.1 | `t2hid`, `t2touchbar_bl`, `t2touchbar_kbd` | `modules/t2touchbar/dkms.conf:1-14` |
| `hid_t2magicmouse` | 0.1 | `hid_t2magicmouse` | `modules/hid_t2magicmouse/dkms.conf` |
| `t2_precision_trackpad` | 0.01 | `t2_precision_trackpad` | `modules/t2_precision_trackpad/dkms.conf` |
| `t2_trackpad_actuator` | 0.01 | `t2_trackpad_actuator` | `modules/t2_trackpad_actuator/dkms.conf` |
| `t2mfi_fastcharge` | 0.1 | `t2mfi_fastcharge` | `modules/t2mfi_fastcharge/dkms.conf` |
| `t2gmux` | 0.8 | `t2gmux` | `modules/t2gmux/dkms.conf` |
| `t2thunderbolt` | 0.6 | `t2thunderbolt` | `modules/t2thunderbolt/dkms.conf` |
| `t2smp` | 0.1 | `t2smp` | `modules/t2smp/dkms.conf` |
| `t2sbs` | 0.1 | `t2sbs` | `modules/t2sbs/dkms.conf` |

Total: **18 kernel objects**. Legacy handling: `t2sep` (0.7, `AUTOINSTALL="no"`) and the retired split
`t2bce_{dma,core,vhci,audio}` are *removed for the running kernel* and then have `AUTOINSTALL="no"` written into
their `dkms.conf` in `/usr/src` (`install-dkms-modules.sh:26-45,136-157`).

Mechanics per module (`install-dkms-modules.sh:200-267`): copy source to `/usr/src/<name>-<version>`
(`:206`,`:210-220`), `dkms add` if absent (`:256-259`), `dkms build --force`, `dkms install --no-depmod --force`
(`:262-263`), then a global `depmod -a` (`:291`). Destination is DKMS's default
`/usr/lib/modules/<kver>/updates/dkms` (`DEST_MODULE_LOCATION[0]="/updates/dkms"` in every `dkms.conf`).

Two DKMS workarounds are installed *system-wide*:

* `/etc/dkms/framework.conf.d/kait2en-disable-post-transaction.conf` containing `post_transaction=""`,
  created for the duration of the run and removed on exit (`:47-61,270-293`).
* `/etc/kernel/install.d/39-kait2en-dkms-cleanup.install` — a kernel-install hook that, on `add <kver>`, removes
  stale `/var/lib/dkms/<mod>/<ver>/<kver>` build trees so a failed DKMS build can be retried
  (`:63-118`).

### 2.5 Non-DKMS kernel module: patched `amdgpu`

`install-gpu-runtime-pm.sh` (invoked with `install --defer-initramfs`, `install.sh:85-86`):

* Model gate: `MacBookPro15,1|MacBookPro16,1|MacBookPro16,4|iMac20,1|iMac20,2` only (`:49-60`).
  **MacBookPro16,2 is not in this list** — the whole step exits early on the target machine (`:183-186`).
* 11 patches from `patches/runtime/gpu-runtime-pm/series:1-11`, one of them version-gated
  ("Merged upstream in 7.3 and backported to stable 7.2.10+", `:146-155`).
* If no local kernel tree, it downloads the matching **Fedora kernel SRPM from Koji**, extracts
  `linux-*.tar.xz`, applies `patch-*-redhat.patch`, then builds the module out of tree
  (`:226-284`). Builds into `/var/tmp` and strips + xz-compresses the result (`:227,289-293`).
* Installs to `/usr/lib/modules/<kver>/updates/kait2en-gpu-runtime-pm/amdgpu.ko.xz` and
  `/usr/lib/modprobe.d/kait2en-gpu-runtime-pm.conf` (`softdep amdgpu pre: t2gmux`) (`:32-33,296-303`).
* Persistence for future kernels: copies itself + `lib.sh` + the patch series to
  `/usr/local/libexec/kait2en/gpu-runtime-pm/` and writes
  `/etc/kernel/install.d/45-kait2en-gpu-runtime-pm.install`, which rebuilds on `add` and deletes on `remove`
  (`:35-36,83-122`). Log at `/var/log/kait2en-gpu-runtime-pm.log` (`:101`).

### 2.6 Kernel command line

`install-kernel-args.sh` — `grubby --update-kernel=ALL --remove-args=... --args=...` (`:133-135`).

Added (`:67-78`, models adjusted at `:80-107`):

```
amdgpu.aspm=1 i915.enable_guc=2 intel_iommu=on iommu=pt pm_async=off brcmfmac.p2pon=0
pcie_aspm=force pcie_aspm.policy=powersave pcie_ports=compat mem_sleep_default=deep
initcall_blacklist=cmos_init,magicmouse_driver_init
module_blacklist=acpi_tad,applesmc,macsmc,hid_apple,hid_appletb_bl,hid_appletb_kbd,hid_magicmouse,appletbdrm,apple_bce,apple_mfi_fastcharge,apple_gmux,sbs
```

Removed first (legacy values): `acpi_osi`, `intel_iommu`, `iommu`, `pm_async`, `brcmfmac.p2pon`, `pci`,
`pcie_ports`, `pcie_aspm`, `nvme_core.default_ps_max_latency_us`, `apple_gmux.force_igd`, `t2gmux.force_igd`,
`amdgpu.aspm`, `i915.enable_guc`, `mem_sleep_default`, `initcall_blacklist`, `module_blacklist` (`:45-65`).

It also *repairs* `/etc/default/grub` when `GRUB_CMDLINE_LINUX=""`, reconstructing it from `/etc/kernel/cmdline`
(`:10-43`) — a write to `/etc/default/grub`, i.e. the classic GRUB path, not BLS-only.

And it drops `/etc/modprobe.d/kait2en-silent-blacklist.conf` with one `install <mod> /bin/true` line per
blacklisted module (`:125-145`).

### 2.7 Initramfs / dracut

`rebuild-initramfs.sh`:

* `/etc/dracut.conf.d/90-kait2en-input.conf` = `force_drivers+=" t2bce_dma t2bce_core t2bce_vhci t2hid t2smc t2sbs "`
  (`:16,22-23`; comment explains t2smc-for-RTC and t2sbs-for-BAT0 ordering, `:10-15`).
* `dracut --force /boot/initramfs-$KVER.img $KVER` (`:19,26`).

Additional dracut config written by the ACPI step (`/etc/dracut.conf.d/t2-acpi-fix.conf`, `acpi-autofix.py:52-55`)
and by Plymouth (`plymouth-set-default-theme -R`, `install-plymouth-theme.sh:62-66`). The AMDGPU step also calls
dracut unless deferred (`install-gpu-runtime-pm.sh:305-307`).

### 2.8 ACPI overrides (runtime-generated firmware tables)

`acpi-autofix.py` reads the machine's own firmware and only acts on two specific log signatures
(`:43-47,214-226`):

* **CpuSSDT** — disassemble `/sys/firmware/acpi/tables/SSDT*` with `CpuSsdt` OEM table id, parse the `SSDT`
  package, derive an `SDTL` bitmask from *already loaded* SSDTs, patch `Name (\SDTL, 0x…)`, bump the OEM
  revision, recompile with `iasl -tc` and require **0 errors and 0 warnings** (`:243-265,412-535,1286-1302`).
* **DSDT** — patch the `_OSC` method **in AML bytes** (CDW3 out-of-bounds field removed, body length preserved,
  Noop padding), bump header revision at offset 24, recompute the checksum, and independently re-verify by
  disassembling baseline and patched table with `iasl -d` (`:1011-1080,1210-1250`).

Deployed files: `/usr/local/lib/firmware/acpi/dsdt.aml`, `<model>CpuSSDT.aml`, `.kait2en-*.sha256` ownership
markers, `/etc/dracut.conf.d/t2-acpi-fix.conf`, backups under `/var/backups/t2-acpi-fix/<ts>/`
(`:38-41,1294-1302,1565-1645`). Ownership is SHA-256-verified; foreign or modified tables are never touched
(`:1435-1464`).

### 2.9 Userspace files written (complete, grouped by root)

**`/usr/local` (not package-managed anywhere):**
`/usr/local/bin/{kait2en-multicall,edit-grub→,update-grub→}` (`install.sh:53-59`);
`/usr/local/libexec/kait2en/kait2en-suspend.sh` (`install-suspend-service.sh:15-16`);
`/usr/local/libexec/kait2en/gpu-runtime-pm/{install-gpu-runtime-pm.sh,lib.sh,patches/}`
(`install-gpu-runtime-pm.sh:35,86-93`);
`/usr/local/share/fonts/kait2en/{JetBrainsMono-Regular.ttf,JetBrainsMono-Medium.ttf}` +
`/usr/local/share/licenses/kait2en-fonts/OFL.txt` (`lib.sh:142-161`);
`/usr/local/share/kait2en/kait2en-wordmark.png` (`install-apps.sh:143-147`);
`/usr/local/libexec/t2-services/{lifecycle.py,t2-ncm-sleep,package-actions,migration/}` (`t2-services/shared/Makefile:10-16`);
`/usr/local/bin/{t2-fancontrol-gtk,t2-smc-control,t2-power-explorer,t2-force-click,t2-debug,t2-zonepower-gtk,t2journal,kait2en-touchbar,t2remote,t2-touchid,t2-kernel-builder,t2-power-tune,t2-hybrid-gpu-control|t2-dgpu-control}` and their per-app helpers/desktop files/icons/polkit policies (`install-apps.sh:151-176`, `t2-services/t2-ave/Makefile:16-22`, `t2-services/t2-journal/Makefile:23-27`, `t2-services/t2-touchid/Makefile:16-26`, per-app `Makefile` install targets);
`/usr/local/lib/systemd/system/*.service` (`t2-fan-control/Makefile:18,42`, `t2-smc-control/Makefile:19,34`, `t2-zone-power/Makefile:41`, `t2-force-click/Makefile:41`, `t2-dgpu-control/Makefile:31`);
`/usr/local/lib/systemd/user/kait2en-touchbar.service` + `/usr/local/lib/udev/rules.d/99-zz-kait2en-touchbar.rules` (`apps/t2-touchbar/Makefile:9-11,30-32`).

**`/usr` (package-owned trees, modified directly):**
`/usr/share/alsa/ucm2/AppleT2/HiFi-x{2,4,6}.conf` + `/usr/share/alsa/ucm2/conf.d/AppleT2x{2,4,6}/` (`install-alsa-ucm.sh:10-11,134-150`);
`/usr/share/t2-dsp/{profiles,pipewire,models.json}`, `/usr/share/wireplumber/wireplumber.conf.d/51-t2-dsp.conf`,
`/usr/share/wireplumber/scripts/t2-default-output.lua`, `/usr/lib/udev/rules.d/89-t2-dsp.rules`,
`/usr/libexec/t2-dsp/{package-actions,lifecycle.py}`, `/usr/share/licenses/t2-dsp/` (`dsp/Makefile:14-29`);
`/usr/share/plymouth/themes/kait2en/*` (`install-plymouth-theme.sh:16-17,48-54`);
`/usr/share/pixmaps/kait2en-gdm-logo.png`, `/usr/share/backgrounds/kait2en/gdm-black.png`
(`install-gdm-branding.sh:12-14,75-86`);
**`/usr/share/gnome-shell/gnome-shell-theme.gresource` is replaced by a locally rebuilt gresource**
(`install-gdm-branding.sh:31-72` — extracts every resource, appends CSS, `glib-compile-resources`, installs over
the distro file);
`/usr/share/selinux/packages/kait2en-t2-touchid.pp` (`install-touchid.sh:18`);
`/usr/lib/modules/<kver>/updates/dkms/*.ko` (DKMS), `/usr/lib/modules/<kver>/updates/kait2en-gpu-runtime-pm/`
(`install-gpu-runtime-pm.sh:296-297`), `/usr/lib/modprobe.d/kait2en-gpu-runtime-pm.conf` (`:33,303`);
`/usr/src/<name>-<version>/` (`install-dkms-modules.sh:206-244`);
`/usr/local/lib/firmware/acpi/*.aml` (ACPI, `acpi-autofix.py:39`);
`/usr/lib/firmware/brcm/brcmfmac*` + `brcmbt4377*` (installer, `installation.py:49,126`).

**`/etc`:**
`/etc/modprobe.d/kait2en-silent-blacklist.conf` (`install-kernel-args.sh:125,138-145`);
`/etc/default/grub` (repair path, `:37-39`);
`/etc/systemd/system/kait2en-suspend.service` (`install-suspend-service.sh:18-35`);
`/etc/systemd/system/kait2en-rtc-sync.service` (`install-rtc-sync.sh:14-27`);
`/etc/systemd/system/t2-services-suspend.service` (`t2-services/shared/Makefile:16-18`, enabled at
`install-t2-services-common.sh:25`);
`/etc/systemd/system/kait2en-t2-remote.service` (`t2-ave/Makefile:19-21`, enabled at `install-t2-remote.sh:16`);
`/etc/systemd/system/kait2en-t2-touchid.service`, `/etc/systemd/system/fprintd.service.d/kait2en-t2-touchid.conf`,
`/etc/kait2en/t2-touchid.conf` (`t2-touchid/Makefile:20-26`, config user binding rewritten at
`install-touchid.sh:28-30`);
`/etc/kait2en/touchbar.toml` (`apps/t2-touchbar/Makefile:12,34`);
`/etc/t2-force-click/config.txt` (`apps/t2-force-click/src/config.rs:109`);
`/etc/environment.d/90-kait2en-gsk-renderer.conf` (`apps/t2-hybrid-gpu-control/Makefile:26-28,58`);
`/etc/NetworkManager/conf.d/10-t2-services.conf` (`install-t2-services-common.sh:98-101`);
`/etc/dconf/db/gdm.d/00-kait2en` (`install-gdm-branding.sh:12,87`) + `dconf update` (`:91`);
`/etc/plymouth/plymouthd.conf` (`install-plymouth-theme.sh:18,56-60`);
`/etc/dracut.conf.d/90-kait2en-input.conf`, `/etc/dracut.conf.d/t2-acpi-fix.conf`,
`/etc/kernel/install.d/39-kait2en-dkms-cleanup.install`,
`/etc/kernel/install.d/45-kait2en-gpu-runtime-pm.install`,
`/etc/dkms/framework.conf.d/kait2en-disable-post-transaction.conf` (transient);
`/etc/xdg/autostart/kait2en-install.desktop` (installed by the Anaconda addon, `installation.py:176-201`);
`/etc/pam.d/*` indirectly through `authselect enable-feature with-fingerprint`
(`packaging/lifecycle/kait2en-lifecycle.py:395-401`);
NetworkManager connection profile created/modified with `nmcli connection add|modify` and stored as a
keyfile under `/etc/NetworkManager/system-connections/` (`install-t2-services-common.sh:115-137`).

**`/var`:**
`/var/lib/dkms/**` (DKMS state, `install-dkms-modules.sh:104`), `/var/lib/kait2en/ownership/<comp>.json` and
`/var/lib/kait2en/migration/` (receipts, `lifecycle.py:34,119`), `/var/lib/kait2en-installer/state`
(`kait2en-prepare:38-43`), `/var/lib/t2-smc-control/gauging` (`apps/t2-smc-control/src/gauging.rs:19`),
`/var/backups/t2-acpi-fix/` (`acpi-autofix.py:41`), `/var/log/kait2en*/` (`install-gpu-runtime-pm.sh:101`,
`lifecycle.py:54`, `installation.py:138-146`), `/var/lib/flatpak/overrides/global`
(`apps/t2-hybrid-gpu-control/Makefile:29,59` — hybrid models only), `/var/cache/libdnf5` (build container only).

**`/boot`:**
`/boot/initramfs-<kver>.img` (rebuilt in place: `rebuild-initramfs.sh:26`, `install-gpu-runtime-pm.sh:306`,
`kait2en-prepare:280`); bootloader entries via `grubby` (`install-kernel-args.sh:133`,
`kait2en-prepare:228,296`, and `grubby --set-default` at `:63,221-224`); `/boot/grub2/grub.cfg` via
`update-grub` → `grub2-mkconfig -o /boot/grub2/grub.cfg` (`kait2en-multicall:8-10`).

**`/run`:** `/run/kait2en/apple-firmware`, `/run/kait2en/*` helpers (`90-kait2en-updates.sh:11-33`),
`/run/systemd/system/{kait2en-live-wifi,kait2en-live-bluetooth}.service` + `multi-user.target.wants` symlinks
(`:42-52`), `/run/kait2en-suspend/` (`kait2en-suspend.sh:5`), `/run/t2-touchid`, `/run/t2remote.sock`,
`/run/t2-power-tune/items.json`.

**User homes:** `~/.local/state/kait2en/install.log` (`kait2en-install:184-187`),
`~/.local/state/wireplumber/{default-profile,default-nodes,default-routes}` edited with `.kait2en.bak` backups
(`install-alsa-ucm.sh:80-120`), `~/.local/state/t2-journal/*`.

### 2.10 systemd units enabled

`systemctl enable` / `--global enable` is called for: `kait2en-suspend.service`
(`install-suspend-service.sh:38`), `kait2en-rtc-sync.service` (`install-rtc-sync.sh:30`),
`t2-services-suspend.service` (`install-t2-services-common.sh:25`), `kait2en-t2-remote.service`
(`install-t2-remote.sh:16`), `kait2en-t2-touchid.service` (`install-touchid.sh:40`),
`t2-fancontrol.service` (`t2-fan-control/Makefile:45`), the smc/zone/force-click unit names
(`t2-smc-control/Makefile:37`, `t2-zone-power/Makefile:44`, `t2-force-click/Makefile:44`),
`kait2en-touchbar.service` **globally** plus `kait2en-touchbar-attach.service` (`apps/t2-touchbar/install.sh:95-96`),
and the live-session units are enabled by symlink in the initramfs pre-pivot hook
(`90-kait2en-updates.sh:42-52`). `dconf update`, `authselect`, `semodule` and `systemctl daemon-reload`/`restart`
round out the runtime activation.

### 2.11 SELinux

One local policy module, built at install time with `checkmodule`+`semodule_package`
(`t2-services/t2-touchid/integration/selinux/Makefile:6-9`), installed from `/usr/share/selinux/packages/` and
loaded with `semodule -X 400 -i` (`lifecycle.py:425`), fingerprinted via `semodule -lfull -m` for later safe
removal (`:420,432-441`). Policy content: a new type `kait2en_touchid_runtime_t` for `/run/t2-touchid`, allowed
on tmpfs, with `fprintd_t` create/write on the socket and `unconfined_service_t` read/connect
(`.te:26-39`, `.fc:1`). `restorecon -R /run/t2-touchid` is run when the directory exists (`install-touchid.sh:37-39`).
No other SELinux changes anywhere; no booleans, no fcontext entries outside `/run`.

### 2.12 PAM

Fingerprint login is enabled by `authselect enable-feature with-fingerprint` with a "before" receipt stored so
removal can detect third-party changes (`lifecycle.py:395-403,405-417`). This mutates `/etc/pam.d` and
`/etc/authselect/` and requires a relogin.

---

## 3. The macOS-side installer kit (the important part)

### 3.1 What it actually modifies

`scripts/macos/prepare-fedora-installer.sh` **writes a stock, checksum-verified Fedora ISO to a USB disk and then
edits only the ISO9660 partition's EFI System Partition**. It refuses an unmodified-ISO mismatch
(`:450-473`), validates the ISO9660 PVD and volume label (`:502-511`), and re-validates the written media
(`:628-637`, `dd … bs=4m`, `:615`).

Writes on the ESP (`:652-676`):

```
$ESP/EFI/BOOT/grub.cfg                                  (overwritten; original saved as grub.cfg.fedora-original)
$ESP/EFI/BOOT/kait2en/kait2en-input-initramfs.img
$ESP/EFI/BOOT/kait2en/kait2en-wifi-initramfs.img
$ESP/EFI/BOOT/kait2en/wifi-firmware.sha256
```

Space is pre-checked (`:655-662`) and every file is `cmp`-verified after writing (`:673-676`). Nothing else on
the medium changes: no squashfs edit, no Anaconda repack, no extra partition. The kit *also* refuses to be used
on atomic desktops at all: "Atomic desktops, Labs, Server, and network-install images are not supported by this
installer kit" (`auto-installer/README.md:45-47`).

GRUB entries are static because "Apple firmware gives GRUB no Ctrl-X or F10" (`grub.cfg.in:26-27`). The KaiT2en
entry appends two initrds after the stock one and injects an Anaconda updates image (`grub.cfg.in:12-19`):

```
set kait2en_common="root=live:CDLABEL=@ISO_VOLUME_LABEL@ rd.live.image inst.updates=file:///run/kait2en/updates.img initcall_blacklist=magicmouse_driver_init"
set kait2en_initrd="($fedora)@ISO_INITRD_PATH@ ($kait2en_efi)/EFI/BOOT/kait2en/kait2en-input-initramfs.img ($kait2en_efi)/EFI/BOOT/kait2en/kait2en-wifi-initramfs.img"
```

### 3.2 How the T2 keyboard/trackpad reach the live system

1. CI builds `kmod-kait2en-input` **against the exact kernel of the ISO** (`targets/fedora-44.conf:8` pins
   `ISO_KERNEL_RELEASE="6.19.10-300.fc44.x86_64"`; `build-input-kmod.sh:55-85` compiles and `rpmbuild`s it with
   `--define kernel_release`, after applying a release-specific compat patch `patches/fedora-44-input.patch`,
   `:59-66`). Only five modules: `t2bce_dma t2bce_core t2bce_vhci t2touchbar(→t2hid) hid_t2magicmouse`
   (`:55`). The RPM `Provides: kernel-modules = %{kernel_release}` and `Requires: kernel-core-uname-r = …` so the
   live system cannot mismatch it (`kmod-kait2en-input.spec:15-16`). The builder asserts vermagic contains the
   ISO kernel release (`build-in-container.sh:129-134`).
2. The kit packs those `.ko` into a **cpio.gz initramfs** with the modules at
   `/usr/lib/modules/<rel>/updates/kait2en/`, plus `/usr/bin/insmod → kmod`, two dracut hooks, the live Wi-Fi/BT
   helpers, and the Anaconda updates image at `/kait2en-anaconda-updates.img`
   (`build-in-container.sh:232-289`; the Anaconda tree inside the updates image is `:149-193`).
3. `pre-trigger/20-kait2en-input.sh` `insmod`s them in dependency order before udev runs
   (`auto-installer/initramfs/20-kait2en-input.sh.in:6-15`: `t2bce_dma t2hid hid_t2magicmouse t2bce_core t2bce_vhci`).
4. `pre-pivot/90-kait2en-updates.sh` copies the Anaconda updates image and the firmware to `/run/kait2en/`,
   which survives switch-root, and installs the two live units into `/run/systemd/system` with
   `multi-user.target.wants` symlinks (`:11-52`).
5. `systemctl --global`-less live units run `kait2en-live-wifi` / `kait2en-live-bluetooth` as oneshots gated on
   `/run/kait2en/apple-firmware` (`kait2en-live-wifi.service:4-10`), which hand the firmware to the same
   `install-wifi-firmware.sh` used for the target system and reload `brcmfmac_wcc` so the live session gets Wi-Fi
   (`kait2en-live-wifi:12-14,43-54`).

### 3.3 How Apple firmware is captured — exact paths and names

**Wi-Fi (all T2 Macs).** Source is derived from what the *running macOS* told the firmware loader. No macOS
partition is mounted and nothing is read from EFI:

```
/usr/sbin/ioreg -l -w0 | grep '"RequestedFiles"' | … | grep -E '/([^/]+\.(trx|clmb|txcb)|P-[^/]+\.txt)$' \
  | sed 's|^|/usr/share/firmware/wifi/|' | sort -u
```

(`prepare-fedora-installer.sh:158-164`) → copies, from the booted macOS root, exactly:

| Extension | Meaning | Source path |
|---|---|---|
| `.trx` | board firmware image | `/usr/share/firmware/wifi/*.trx` |
| `.clmb` | CLM regulatory blob | `/usr/share/firmware/wifi/*.clmb` |
| `.txcb` | TxCap blob | `/usr/share/firmware/wifi/*.txcb` |
| `P-*.txt` | per-board NVRAM, `P-<board>_M-<module>_V-<vendor>__m-<version>.txt` | `/usr/share/firmware/wifi/P-*.txt` |

Exactly one of each is required (`pick_one`, `:104-113,528-531`) and the three names must agree
(`:533-542`). If `ioreg` reports nothing the kit dies with "Enable Wi-Fi, reboot macOS, and retry, or use
`--firmware-dir`" (`:166-168`) — i.e. the Wi-Fi hardware must have been *active* in macOS for the list to exist.

**Bluetooth (BCM4377 PCIe only).** `system_profiler SPBluetoothDataType` → chipset string `BCM4377…`; if the
chipset is not 4377 it skips (`:189-200`). Source files: `/usr/share/firmware/bluetooth/BCM4377*.bin` and
`*.ptb` (`:206-210`), overridable with `KAIT2EN_BT_FIRMWARE_ROOT` (`:184`).

**How the destination names are chosen.** The kernel asks for a *specific* file name; the kit reads the request
out of the boot log instead of guessing:

```
sed -n 's|.*Direct firmware load for \(brcm/brcmfmac[^ ]*\.apple,[^ ]*\.bin\) failed with error -2.*|\1|p'
sed -n 's|.*brcm_fw_alloc_request: using \(brcm/brcmfmac[^ ]*-pcie\) for chip .*|\1|p'
```

(`install-wifi-firmware.sh:96-118`), then composes
`<brcmfmacXXXX-pcie>.apple,<board>.clm_blob`, `.apple,<txcap>.txcap_blob` and
`.apple,<board>-<module>-<vendor>-<version>.txt` (`:134-145`). For Bluetooth the driver prints both names it
tried (`install-bt-firmware.sh:76-80`) and the Apple filename is parsed with
`^BCM([0-9]{4})([A-Z][0-9])_.*_PCIE_([^_]+)_MFG_([^_]+)_.*_PROD\.signed\.bin$` to derive
`brcmbt<chip><stepping>-apple,<board>[-m|-u]` (`:98-128`), with `GEN→""`, `MUR→-m`, `USI→-u` (`:115-120`).

**What identifies a model.** Three different keys are in play, and none of them is a single "model number":

* `board` (e.g. `trinidad`-style base from the `.trx` file name, `install-wifi-firmware.sh:82-84`);
* `module/vendor/version` from the `P-*.txt` NVRAM filename (`:66-73`);
* the chip/stepping from the Apple BT filename, and the PCI id `14e4:5fa0` for BT presence
  (`install-bt-firmware.sh:55-66,82`);
* DMI `product_name` is used elsewhere (`acpi-autofix.py:167-177`, `lib.sh:128-133`) but **not** to pick
  firmware.

The Bluetooth board type additionally must exist in the *kernel's* DMI table; if hci_bcm4377 prints "unable to
determine board type" the installer refuses and asks for a bug report (`install-bt-firmware.sh:84-93`,
`auto-installer/README.md:49-55` — currently MacBookAir9,1, MacBookPro15,4, MacBookPro16,3). **MacBookPro16,2 is
not in that list**, so on the target machine Bluetooth firmware installation is expected to be refused; unclear
from source whether the kernel table has since been extended.

### 3.4 How the firmware reaches the installed system

Two independent carriers, both ending in the same rename helper:

1. **The USB stick** — `kait2en-wifi-initramfs.img` is a cpio.gz holding `kait2en-wifi-firmware/` plus
   `SHA256SUMS` (`prepare-fedora-installer.sh:517-582`). The pre-pivot hook copies it to
   `/run/kait2en/apple-firmware` with the comment "Nothing placed here reaches the installed system"
   (`90-kait2en-updates.sh:18-23`).
2. **The Anaconda addon** — `InstallWifiFirmwareTask` runs
   `bash install-wifi-firmware.sh --source /run/kait2en/apple-firmware --root <sysroot>` and then requires ≥4
   `brcmfmac*.apple,*` files in `<sysroot>/usr/lib/firmware/brcm` or fails the installation
   (`installation.py:33-60`). `InstallBluetoothFirmwareTask` is best-effort, writes a report to
   `<sysroot>/var/log/kait2en/bluetooth-firmware.log`, and never fails the install (`:63-148`).
   Resulting files: `/usr/lib/firmware/brcm/brcmfmac<chip>-pcie.apple,<board>{,.clm_blob,.txcap_blob,-…txt}` and
   `/usr/lib/firmware/brcm/brcmbt<chip><st>-apple,<board>[-m|-u].{bin,ptb}`.

The same addon installs a **transition kmod RPM** into the target (`rpm --install --replacepkgs … root=sysroot`,
`depmod -a`, `dracut --force --add-drivers …`), verifies the modules are inside the target initramfs with
`lsinitrd`, and adds
`initcall_blacklist=magicmouse_driver_init` + `module_blacklist=acpi_tad,…,apple_mfi_fastcharge,apple_gmux`
through Anaconda's bootloader API (`installation.py:204-259,262-278`, `constants.py.in:15-18`). This is what
guarantees a keyboard exists on first boot of the installed system before DKMS has run.

### 3.5 Could the firmware be obtained other than from the Mac?

From the source, three routes exist and only one is supported:

* **Supported:** read it off the running macOS (above). Equivalent manual path: `brcm_fw.sh` on macOS writes the
  same files to the internal ESP under `/firmware/`, then on Linux copies them to `/lib/firmware/brcm`
  (`scripts/fedora/deprecated/brcm_fw.sh:108-113,176-218,327-331`).
* **Explicitly refused:** third-party redistribution packages `apple-bcm-firmware`, `apple-firmware`,
  `t2-apple-firmware` — the script *errors out* if one is installed (`brcm_fw.sh:69-101`). That is a policy
  decision based on redistribution of Apple firmware, and it matters for an image: baking these blobs into a
  public image repeats exactly what the project refuses to depend on.
* **Not evidenced:** `scripts/fedora/other/download-bootcamp-drivers.py` downloads Boot Camp ESDs from Apple's
  software-update catalog using only a *model identifier* (`:24,38-61,244-332`) and extracts
  `WindowsSupport.dmg` (`:394-417`). **Unclear from source** whether that payload contains the exact
  `.trx/.clmb/.txcb/P-*.txt`/`BCM4377*.bin/.ptb` files, and no code in the tree consumes them; it is an
  inherited Brigadier tool, not part of the install path.

Consequence for the image: firmware is per-machine, licence-encumbered, and must be supplied at install/first-boot
(from the ESP, a user-provided `--firmware-dir`, or a post-install fetch), not baked.

---

## 4. Kernel side

* **Policy: stock Fedora kernel, no custom kernel.** "KAIT2EN keeps Fedora's vanilla kernel and installs T2
  hardware support as a separate layer" (`website/docs/reference/installed-files.md:3-4`, matching
  `README.md:7-8`: "You will receive kernel updates directly from Fedora"). No kernel RPM is built or shipped by
  the install path; COPR kernel builds are opt-in *experiments* only (`scripts/copr/README.md:1-27`).
* **Minimum kernel 7.0.** `require_min_kernel 7 0` (`scripts/fedora/lib.sh:177-191`, called at
  `install.sh:8`); the guided installer likewise filters `rpm -q kernel-core` for `>= 7` and refuses with "no
  installed Fedora kernel version 7 or newer" (`kait2en-prepare:230-237`), and short-circuits when the running
  kernel is already ≥ 7 (`:214-219`).
* **Supported Fedora release: 44** (`auto-installer/targets/fedora-44.conf:1-2`, `ARCH="x86_64"`), ISO built
  for kernel `6.19.10-300.fc44.x86_64` (`:8`), Anaconda `44.30-2.fc44` (`:9`), editions Workstation / KDE /
  COSMIC from Fedora 44-1.7 (`targets/fedora-44-editions.tsv:1-3`). Because the installer needs ≥ 7.0 while the
  ISO ships 6.19, phase 1 upgrades the machine first — this is the intended path, not an edge case.
  **Unclear from source** which Fedora 44 update stream supplies the ≥ 7.0 kernel.
* **DKMS, never akmods.** Every module has a `dkms.conf` with `AUTOINSTALL="yes"` and
  `DEST_MODULE_LOCATION="/updates/dkms"`; there is no `akmod-*` spec, no `kmodtool`, and the string "akmod"
  appears nowhere in the tree. Naming therefore follows DKMS: `/usr/src/<name>-<PACKAGE_VERSION>/`,
  `/var/lib/dkms/<name>/<version>/<kver>/`, `/usr/lib/modules/<kver>/updates/dkms/<mod>.ko`.
* **Versioning is per-package, hand-edited in `dkms.conf`** (e.g. `t2bce_stack 0.01`, `t2gmux 0.8`,
  `t2thunderbolt 0.6`, `t2sep 0.7`, everything else `0.1`/`0.01`). There is no single project version, no
  kernel-compat matrix, and no per-kernel branching — compatibility is achieved by (a) the ≥ 7.0 floor,
  (b) a per-Fedora-release input compat patch for the installer kernel (`patches/fedora-44-input.patch`), and
  (c) version-gated patch skipping for `amdgpu` (`install-gpu-runtime-pm.sh:146-155`).
* **Build target is the running kernel, always.** `dkms build/install` are called without `-k` and
  `lib.sh:167-175` comments that they "always target the running kernel whatever `KERNEL_RELEASE` says" — the
  only place `KERNEL_RELEASE` is honoured is `install-dependencies.sh:10` and `kait2en-prepare:247`.
* **Secure Boot is not supported.** No signing, no MOK enrolment, no key handling in the tree. The macOS kit
  instead checks NVRAM `AppleSecureBootPolicy` and prints "Set Secure Boot to No Security"
  (`prepare-fedora-installer.sh:87-102`, asserted by `scripts/tests/static-check.sh:242-244`).
* **Kernel-install hooks are the extension point**: `39-kait2en-dkms-cleanup.install` (DKMS retry cleanup),
  `45-kait2en-gpu-runtime-pm.install` (rebuild patched amdgpu between `40-dkms` and `50-dracut`),
  `90-kait2en-input.conf` for dracut force_drivers. Anything that rebuilds the image must preserve or replace
  these three mechanisms.

---

## 5. What breaks under an immutable rpm-ostree/bootc system

Ordered by severity. Each item is a concrete call site, not a general worry.

1. **Runtime package management.** `dnf install -y <pkg>` per package (`install-dependencies.sh:57-62`),
   `dnf install` for DSP deps (`install-dsp.sh:33-35`), for the AMDGPU build deps (`install-gpu-runtime-pm.sh:202-212`),
   for Touch Bar deps (`apps/t2-touchbar/install.sh:57`), `dnf swap`/`dnf install` from RPM Fusion
   (`install-hardware-video-decoding.sh:65,67`), and above all
   `dnf upgrade --refresh -y --setopt=installonly_limit=0` (`kait2en-prepare:227`). On bootc `/usr` is read-only
   and `dnf` fails; on rpm-ostree these become `rpm-ostree install` + reboot (or must vanish into the image).
2. **Compiling kernel modules on the host, into `/usr`.** `dkms build/install` (`install-dkms-modules.sh:262-263`)
   and `make -C <kernel tree> M=… modules` for amdgpu (`install-gpu-runtime-pm.sh:283`) write
   `/usr/lib/modules/<kver>/updates/…` and `/usr/src/…`. This is impossible on both rpm-ostree (`/usr` read-only)
   and bootc, and it is fundamentally incompatible with "kernel comes from the image": the build would have to
   happen inside the image build against that image's kernel.
3. **`/boot` and bootloader manipulation.** `dracut --force /boot/initramfs-<kver>.img`
   (`rebuild-initramfs.sh:26`, `install-gpu-runtime-pm.sh:306`, `kait2en-prepare:280`),
   `grubby --update-kernel=ALL --args/--remove-args` (`install-kernel-args.sh:133-135`),
   `grubby --set-default(-index)` (`kait2en-prepare:63,228,296`), `grub2-mkconfig -o /boot/grub2/grub.cfg`
   (`kait2en-multicall:9`), `/etc/default/grub` rewrite (`install-kernel-args.sh:37-39`). On ostree the
   deployment owns kernel args (`rpm-ostree kargs`), the initramfs is generated per deployment, and
   `grub2-mkconfig` is not the owner of the BLS entries.
4. **Package-owned files replaced in place.** `/usr/share/gnome-shell/gnome-shell-theme.gresource` is compiled
   and installed over the distro file (`install-gdm-branding.sh:31-72`); `/usr/share/alsa/ucm2/AppleT2/*` is
   written and old profiles `rm -f`'d (`install-alsa-ucm.sh:134-150`); `/usr/share/plymouth/themes/kait2en/` is
   `rm -rf`'d and re-created (`install-plymouth-theme.sh:48-54`). Under ostree these become unmanaged
   modifications that conflict on upgrade; under bootc they break the "everything in /usr comes from the image"
   contract.
5. **`/usr/local` as the install prefix.** Binaries, libexec helpers, systemd units, udev rules, polkit policies
   and licenses all go to `/usr/local/…` (`install.sh:53-57`, `install-apps.sh:143-147`,
   `apps/t2-touchbar/Makefile:8-13`, `install-suspend-service.sh:15-16`). `systemctl enable` then creates
   symlinks in `/etc/systemd/system` for units that live outside any package. On an image, `/usr/local` must be
   built in and enablement must be presets/`WantedBy` from the image, not a runtime `enable`.
6. **`systemctl enable` at install time.** `install-suspend-service.sh:38`, `install-rtc-sync.sh:30`,
   `install-t2-services-common.sh:25`, `install-t2-remote.sh:16`, `install-touchid.sh:40`,
   `t2-fan-control/Makefile:45`, `t2-smc-control/Makefile:37`, `t2-zone-power/Makefile:44`,
   `t2-force-click/Makefile:44`, `apps/t2-touchbar/install.sh:95-96`. Enablement written into `/etc` survives
   rebases but is invisible to a fresh install of the image; the correct model is unit `[Install]` + a
   `systemctl preset`/`preset-all` at build (and `systemctl --global enable` for the user unit).
7. **SELinux policy loaded at runtime.** `semodule -X 400 -i` (`lifecycle.py:425`) writes the policy store; a
   policy module must be built and installed in the image instead (or the type must be dropped entirely in
   favour of an existing type). `restorecon` on `/run` (`install-touchid.sh:37-39`) stays a runtime action.
8. **PAM changed at runtime.** `authselect enable-feature with-fingerprint` (`lifecycle.py:401`) belongs in the
   image build; doing it at first boot on an already-configured system risks fighting the user's own
   `authselect` selection.
9. **NetworkManager profile creation with `nmcli`.** `nmcli connection add/modify …` and deletion of
   auto-created profiles (`install-t2-services-common.sh:115-145`) requires a running NetworkManager and a
   device (or MAC) to bind; on a build host there is no T2 NCM interface. Must be a keyfile baked into
   `/usr/lib/NetworkManager/system-connections/` or a first-boot action.
10. **Group/user mutation.** `groupadd --system kait2en-touchbar` and `usermod -aG` (`apps/t2-touchbar/install.sh:63-64`).
    Belongs in `sysusers.d`/image; `usermod` on a user that does not exist yet at build time is meaningless.
11. **DMI/PCI gating at install time.** `has_touch_bar` (`lib.sh:128-133`), GPU-app selection
    (`install-apps.sh:106-139`), AMDGPU support list (`install-gpu-runtime-pm.sh:49-60`), kernel-arg model
    exceptions (`install-kernel-args.sh:80-107`), ACPI model naming (`acpi-autofix.py:1294-1302`), Bluetooth
    `14e4:5fa0` probe (`install-bt-firmware.sh:55-66`). A container build sees the *builder's* DMI, so every one
    of these silently takes the "not my model" branch. They must be converted to runtime decisions
    (udev/systemd `Condition*`, module autoloading, DMI-matched drop-ins) or to "install the union, gate at
    runtime".
12. **Machine-specific firmware tables.** ACPI overrides require `/sys/firmware/acpi/tables` and the running
    kernel log (`acpi-autofix.py:38-47,191-226`) — impossible in a build container, and the tables are
    per-machine anyway.
13. **Per-machine, non-redistributable firmware.** As in §3.5.
14. **The guided two-phase installer itself.** `kait2en-install`/`kait2en-prepare` exist to (a) upgrade Fedora
    until the kernel is ≥ 7.0, (b) build transition modules for the *next* kernel and park them in its
    initramfs, (c) set that kernel default (`kait2en-prepare:226-298`). With an image that is already at the
    right kernel, the whole mechanism is dead weight — but its *purpose* (a working keyboard before DKMS exists)
    still has to be met by baking the modules into the image's initramfs.
15. **Minor but real:** `fc-cache -f` (`lib.sh:156-157`), `gtk-update-icon-cache` (`install-apps.sh:70-71`,
    `t2-hybrid-gpu-control/Makefile:60`), `dconf update` (`install-gdm-branding.sh:91`),
    `udevadm control --reload` + `udevadm trigger` (`apps/t2-touchbar/install.sh:97-116`), `flatpak override
    --system` (`t2-hybrid-gpu-control/Makefile:59`), `sed -i` on the user's WirePlumber state
    (`install-alsa-ucm.sh:98-114`). All of these are build-time cache generation or first-boot activation, never
    image-build-safe as written.

Not a problem: `/opt` is never used; `/var` writes are all either receipts (fine, `/var` is writable) or DKMS
state (goes away with item 2).

---

## 6. Portability classification

Classes: **A** = works as-is in an image build · **B** = needs image-build adaptation (what) · **C** = must stay
a runtime / first-boot step (why) · **D** = hardware-dependent, cannot be baked.

| # | Item | Evidence | Touches | Class | Note |
|---|---|---|---|---|---|
| 1 | 12 DKMS packages / 18 `.ko`, built per running kernel | `install-dkms-modules.sh:11-24,249-267`; every `modules/*/dkms.conf` | `/usr/src`, `/usr/lib/modules/<kver>/updates/dkms`, `/var/lib/dkms` | **B** | Must become prebuilt kmods for the image's kernel(s) — the akmods pattern — built and signed in the image pipeline, not on the host. Nothing else in the tree can compile them. |
| 2 | Patched out-of-tree `amdgpu` (11 patches) | `install-gpu-runtime-pm.sh:49-60,226-303`; `patches/runtime/gpu-runtime-pm/series:1-11` | `/usr/lib/modules/<kver>/updates/kait2en-gpu-runtime-pm`, `/usr/lib/modprobe.d`, `/usr/local/libexec`, `/etc/kernel/install.d/45-*` | **B** (not applicable to MBP16,2) | Not for the target machine: model list excludes `MacBookPro16,2` (`:55`). For a general Bluefin-T2 image it needs a prebuilt module + a baked modprobe conf; the runtime hook cannot exist. |
| 3 | Installer transition kmod (`kmod-kait2en-input`, 5 modules) | `kmod-kait2en-input.spec:27-47`; `build-input-kmod.sh:55-92`; `installation.py:204-259` | target `/usr/lib/modules/<rel>/updates/kait2en`, target initramfs | **B** | The *purpose* survives (keyboard before userspace) but the mechanism becomes "these 5 modules are in the image and in the image initramfs". The per-ISO-kernel build is unnecessary when the image pins its own kernel. |
| 4 | `force_drivers` dracut config | `rebuild-initramfs.sh:16-26` | `/etc/dracut.conf.d/90-kait2en-input.conf`, `/boot/initramfs-<kver>.img` | **B** | The conf file is fully bakeable; the `dracut --force` call is not — the image's own initramfs must be regenerated with it. |
| 5 | Kernel arguments (11 added, 16 removed, per-model exceptions) | `install-kernel-args.sh:45-78,80-107,133-135` | BLS entries / `grub.cfg` via `grubby`, `/etc/default/grub` | **B** | Baked via `rpm-ostree kargs`/bootc containerfile `kargs` — but the per-model exceptions (`iMac*`, `MacBookPro16,1`) cannot be evaluated at build time; either ship the safe union or gate at runtime. |
| 6 | `module_blacklist` + `/etc/modprobe.d/kait2en-silent-blacklist.conf` | `install-kernel-args.sh:109-127,138-145` | cmdline + `/etc/modprobe.d` | **B** | Cmdline part → kargs; the 12 `install <mod> /bin/true` lines are a plain bakeable file. |
| 7 | Fedora + build packages (~28) | `install-dependencies.sh:24-62`; `install-dsp.sh:33-35`; `apps/t2-touchbar/install.sh:57` | rpmdb | **B** | Move into the image's package list (Containerfile). Watch: `cargo`/`rust`/`gtk4-devel` etc. are *build*-only and should not ship. |
| 8 | RPM Fusion free/nonfree + VA-API drivers | `install-hardware-video-decoding.sh:31-46,71-79` | repos, `mesa-va-drivers-freeworld`, `intel-media-driver` | **B** | Not in the install path today (no caller); if wanted, enable rpmfusion at build. Repo policy decision for Bluefin. |
| 9 | Rust/GTK apps built as the invoking user, installed to `/usr/local` | `install-apps.sh:79-101,151-176`; `apps/*/Makefile` | `/usr/local/{bin,libexec,share}`, `/usr/local/lib/systemd/system`, `/usr/local/lib/udev/rules.d` | **B** | Build as packages in the image; `sudo -H -u $SUDO_USER` + `make` has no meaning in a container. All 13 binaries must ship in `/usr`, not `/usr/local`, or `/usr/local` must be part of the image. |
| 10 | `systemctl enable` for 8+ units | `install-suspend-service.sh:38`; `install-rtc-sync.sh:30`; `install-t2-services-common.sh:25`; `install-t2-remote.sh:16`; `install-touchid.sh:40`; `t2-fan-control/Makefile:45`; `t2-smc-control/Makefile:37`; `t2-zone-power/Makefile:44`; `t2-force-click/Makefile:44`; `apps/t2-touchbar/install.sh:95-96` | `/etc/systemd/system/*.wants` | **B** | Replace with `[Install]` + `systemctl preset-all` at build (and `--global` for the user unit). |
| 11 | `kait2en-suspend.service` + `kait2en-suspend.sh` (BCM unload/reload around sleep) | `install-suspend-service.sh:18-38`; `scripts/fedora/kait2en-suspend.sh:1-170` | `/etc/systemd/system`, `/usr/local/libexec`, `/run/kait2en-suspend` | **A** | Pure runtime behaviour, no build-host dependency, no package manager. Only the unit's location needs moving into `/usr`. |
| 12 | `kait2en-rtc-sync.service` (`chronyc waitsync && hwclock --systohc`) | `install-rtc-sync.sh:19-25` | `/etc/systemd/system` | **A** | Runtime-only. |
| 13 | `t2-services-suspend.service` + `t2-ncm-sleep` + AVE sleep hook | `t2-services/shared/Makefile:10-21`; `t2-ave/Makefile:22` | `/usr/local/libexec/t2-services`, unit | **A** | Runs at sleep time; needs units in the image. |
| 14 | `kait2en-t2-remote.service` + `t2remote` (`modprobe t2bce_ave`) | `t2-ave/integration/systemd/kait2en-t2-remote.service:8-9`; `t2-ave/Makefile:16-22` | `/usr/local/bin`, unit | **A** (given #1) | Depends on `t2bce_ave` existing, i.e. on item 1. |
| 15 | `kait2en-t2-touchid.service`, fprintd drop-in, D-Bus policy, config | `t2-touchid/Makefile:16-26`; `install-touchid.sh:25-30` | `/usr/local/bin`, `/etc/systemd/system`, `/usr/share/dbus-1/system.d`, `/etc/kait2en` | **B** | Files bake cleanly; the first-install-only `sed` that writes `T2_TOUCHID_BIND_USER` (`install-touchid.sh:28-30`) must become a documented first-boot/user step, because the build host has no such user. |
| 16 | Touch ID SELinux module | `t2-touchid/integration/selinux/{Makefile:6-11,*.te:1-39,*.fc:1}`; `lifecycle.py:424-425` | `/usr/share/selinux/packages`, policy store `-X 400` | **B** | Compile `.pp` and install with `semodule` in the image build; at runtime only `restorecon /run/t2-touchid` remains. |
| 17 | `authselect enable-feature with-fingerprint` | `lifecycle.py:395-403` | `/etc/pam.d`, `/etc/authselect` | **B** | Do it at build (`authselect select … with-fingerprint`); the runtime receipt/rollback logic is unnecessary and conflicts with user choice. |
| 18 | ALSA UCM profiles for AppleT2 | `install-alsa-ucm.sh:122-150`; `modules/t2bce_audio-alsa-ucm-conf/ucm2/**` | `/usr/share/alsa/ucm2/AppleT2`, `conf.d/AppleT2x{2,4,6}` | **A** | Plain data files under `/usr`; `rm -f` of two superseded files is a one-time build cleanup. |
| 19 | Audio DSP (profiles, WirePlumber conf, udev rule, `package-actions`) | `dsp/Makefile:14-29`; `install-dsp.sh:33-48`; `dsp/integration/libexec/package-actions:12-16` | `/usr/share/t2-dsp`, `/usr/share/wireplumber`, `/usr/lib/udev/rules.d`, `/usr/libexec/t2-dsp`, `/etc` migrations | **A** for files, **C** for migrations | Runtime selection is udev/WirePlumber-driven and model-agnostic (`dsp/README.md:16-23`). Note `MacBookPro16,2 → profile 16_2` exists (`dsp/README.md:46`). Legacy `/etc` migration only matters for converted systems. |
| 20 | Plymouth theme + `plymouthd.conf` (`DeviceScale=1`, `UseSimpledrm=0`) | `install-plymouth-theme.sh:16-18,48-66` | `/usr/share/plymouth/themes`, `/etc/plymouth` | **A** | `plymouth-set-default-theme -R` rebuilds the initramfs → absorb into #4. |
| 21 | GDM branding + **rebuilt `gnome-shell-theme.gresource`** | `install-gdm-branding.sh:12-14,31-99` | `/etc/dconf/db/gdm.d`, `/usr/share/gnome-shell/gnome-shell-theme.gresource`, pixmaps, backgrounds | **B** | The gresource replacement must be produced in the build (or dropped: it only sets a black login background) — it overwrites a gnome-shell -owned file. `dconf update` is build-time cache generation. |
| 22 | ACPI overrides (CpuSSDT + DSDT `_OSC`) | `acpi-autofix.py:38-55,214-226,1011-1080,1565-1645` | `/usr/local/lib/firmware/acpi`, `/etc/dracut.conf.d`, `/var/backups`, initramfs | **D** + **C** | Requires *this machine's* ACPI tables and *this machine's* kernel log; the generated table is per-model and validated against the live firmware. At most a first-boot generator can be shipped; the override itself must be produced on the machine. |
| 23 | Apple Wi-Fi firmware (`.trx/.clmb/.txcb/P-*.txt`) | `prepare-fedora-installer.sh:152-180`; `installation.py:26-60`; `install-wifi-firmware.sh:136-145` | macOS `/usr/share/firmware/wifi` → `/usr/lib/firmware/brcm` | **D** | Per-machine, captured from macOS, non-redistributable (project refuses the redistribution packages, `brcm_fw.sh:69-101`). Must be a first-boot/installer-time step reading the ESP or a user-supplied directory. |
| 24 | Apple Bluetooth firmware (BCM4377 only, needs `.ptb` pair) | `prepare-fedora-installer.sh:182-213`; `install-bt-firmware.sh:84-93,187-192` | macOS `/usr/share/firmware/bluetooth` → `/usr/lib/firmware/brcm` | **D** | Same licensing; additionally gated by the kernel's DMI board table, which today lacks MacBookPro16,2 (`auto-installer/README.md:49-55`). |
| 25 | Live-session Wi-Fi/BT units + `/run/kait2en` bridge | `90-kait2en-updates.sh:11-52`; `kait2en-live-wifi.service:1-13` | `/run`, `/run/systemd/system` | **C** (live only) | Only exists for the Anaconda live image; irrelevant to a Bluefin install, but the *concept* (make Wi-Fi work in the installer environment) is still needed on a net-installing Bluefin image. |
| 26 | Transition-kernel install / initramfs parking / default-kernel flip | `kait2en-prepare:214-298` | rpmdb, `/boot`, BLS | **C → delete** | Exists only to bridge the "no DKMS yet" window. On an image this is satisfied at build; the code has no image analogue. `dnf upgrade … installonly_limit=0` (`:227`) must not survive in any form. |
| 27 | Guided installer (repo checkout, git pull, re-exec) | `kait2en-install:42-153,191-224`; `kait2en-prepare:127-168` | `/usr/local/src/KaiT2en-Fedora`, `/usr/local/bin`, `/var/lib/kait2en-installer`, `~/.local/state` | **C → replace** | Self-updating source checkout that runs `dnf`/`dkms`/`grubby`. Under an image, updates must come from the image (`bootc upgrade`); a "run the upstream installer" path must not exist. |
| 28 | Anaconda addon (firmware + transition RPM + kernel args into target root) | `installation.py:26-278`; `kait2en.py:24-33` | target sysroot `/usr/lib/firmware`, `/usr/lib/modules`, `/boot/initramfs`, `/usr/share/kait2en-installer`, `/etc/xdg/autostart` | **C → redesign** | Bound to Anaconda's `KickstartService` API (`kait2en.py:16,24-33`) and to a writable target root. Bluefin's installer path is not Anaconda-with-addon, so this whole hook has to be re-homed (or the firmware step moved to first boot). |
| 29 | USB kit: ISO verify, `dd`, ESP edits, GRUB rewrite | `prepare-fedora-installer.sh:450-511,608-681`; `grub.cfg.in:1-47` | USB ESP only | **C** (different shape) | Nothing about `grub.cfg.in` survives for a bootc/ostree installer, but the *firmware capture + carry* half is reusable verbatim on any medium (e.g. write firmware to the ESP, read at first boot). Explicitly refuses atomic images (`auto-installer/README.md:45-47`). |
| 30 | NetworkManager `Apple T2 Bridge` profile via `nmcli` | `install-t2-services-common.sh:29-147` | `/etc/NetworkManager/system-connections`, `/etc/NetworkManager/conf.d` | **C** | Needs a live NCM device to bind by MAC; the `10-t2-services.conf` (`no-auto-default=ac:de:48:00:11:22`) and the keyfile both bake fine, the *creation* must be first boot. |
| 31 | `kait2en-touchbar` group + user membership | `apps/t2-touchbar/install.sh:63-64`; `Makefile:8-13,27-35`; `udev/99-zz-kait2en-touchbar.rules:1-38` | `/etc/group`, `/etc/passwd`, `/usr/local`, `/etc/kait2en` | **B** + **C** | Group via `sysusers.d` at build; `usermod -aG` for the desktop user is first-login/runtime (the image does not know the user). udev rule and units bake fine. |
| 32 | Fonts, wordmark, icon caches, flatpak override, `/etc/environment.d` | `lib.sh:142-161`; `install-apps.sh:143-147`; `t2-hybrid-gpu-control/Makefile:58-59` | `/usr/local/share`, `/etc/environment.d`, `/var/lib/flatpak` | **A/B** | Files bake; `fc-cache`/`gtk-update-icon-cache`/`dconf update` must run in the build (they are cache generation, not activation). |
| 33 | `kait2en-multicall` (`edit-grub`, `update-grub`) | `scripts/fedora/kait2en-multicall:1-15` | `/usr/local/bin` | **B → drop** | `grub2-mkconfig -o /boot/grub2/grub.cfg` is exactly the wrong contract for an ostree deployment; replace with `rpm-ostree kargs` guidance. |
| 34 | t2-cpu-control removal, legacy profile cleanup, obsolete-unit disabling | `install-apps.sh:9-72`; `install-t2-services-common.sh:86-94`; `install-alsa-ucm.sh:136-140`; `install-dkms-modules.sh:136-157` | `/usr/local`, `/etc`, `/usr/src/*/dkms.conf` | **B → drop** | Migration logic for a mutable install history. On an image the old state never exists; keeping it means advertising files nothing owns. |
| 35 | `t2-kernel-builder` | `install-apps.sh:170-173`; `apps/t2-kernel-builder/install.sh:35` | `/usr/local/bin`, `/usr/local/libexec/t2-kernel-builder/*` | **B** | An app whose purpose is building custom kernels on the host — directly opposed to an immutable model. Ship it or not, but it cannot function (needs `dnf install kernel-devel`, writes `/boot` + `/lib/modules`). |
| 36 | Hardware-video-decoding script (RPM Fusion swap) | `install-hardware-video-decoding.sh:31-138` | repos, `dnf swap` | **B** | No caller in tree; if wanted, bake the freeworld drivers at build. |
| 37 | COPR kernel experiments | `scripts/copr/README.md:1-43`; `.github/workflows/kernel-copr.yml` | COPR project, separate kernel RPM | **D** (out of scope) | Not part of the product install; relevant only as evidence that a patched kernel is a *research* channel, not a shipping one. |

### Counts

* **A** (works as-is / data or pure runtime): items 11, 12, 13, 14, 18, 19, 20, 32 — all still need their files
  placed in `/usr` by an image, but no logic changes.
* **B** (image-build adaptation): 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17, 21, 31(build half), 33, 34, 35, 36.
* **C** (must stay runtime/first-boot): 25, 26, 27, 28, 29, 30, 31(membership half), 22(execution half),
  19(migrations only).
* **D** (hardware-dependent, cannot be baked): 22, 23, 24, 37.

### The three items that decide the architecture

1. **Module delivery (item 1/3/4).** The image must ship prebuilt, kernel-matched, signed T2 modules *and* an
   initramfs containing the five input modules. That is the akmods pattern, and it is the single largest piece of
   new machinery — KaiT2en-Fedora has no equivalent (no signing, no prebuilt RPMs, no kernel matrix).
2. **Firmware supply (items 23/24).** Per-machine, non-redistributable, read from macOS, named after a runtime
   kernel request. It cannot be in the image; it needs an installer/first-boot channel that survives the image
   boundary (ESP carry, or a user-supplied directory).
3. **Everything DMI-conditional (item 11).** Today the installer *decides on the machine it runs on*. On an image
   the build host is not a T2 Mac, so every gate (`has_touch_bar`, GPU app selection, AMDGPU list, kernel-arg
   exceptions, ACPI model naming, BT board table) must either become a runtime condition or be resolved to the
   union of all models.

## 7. Explicit unknowns

* Which Fedora 44 update stream carries the ≥ 7.0 kernel that `require_min_kernel 7 0` demands, given
  `targets/fedora-44.conf:8` pins the ISO at `6.19.10-300.fc44.x86_64`. The code path is clear; the kernel's
  provenance is not in the tree.
* Whether the `post_transaction` key honoured by `install-dkms-modules.sh:54-61` exists in the `dkms` version
  Fedora 44 ships (`/etc/dkms/framework.conf.d/` support) — not verifiable from this repository.
* Whether Boot Camp ESD payloads (`download-bootcamp-drivers.py:24,394-417`) contain the exact
  `.trx/.clmb/.txcb/P-*.txt` / `BCM4377*.bin/.ptb` files needed here. No code consumes them; the tool is inherited.
* Whether the in-kernel `hci_bcm4377` DMI board table now covers `MacBookPro16,2`. The repo's own README lists
  only MacBookAir9,1 / MacBookPro15,4 / MacBookPro16,3 (`auto-installer/README.md:49-55`).
* `packaging/installer/runtime/kait2en-install` was not diffed against
  `auto-installer/runtime/kait2en-install`; it is described in the tree as the packaged copy and plays the same
  role.
