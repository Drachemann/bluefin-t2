# Design v2: Bluefin Classic with KAIT2EN's T2 support

Status: **v2 — amended after the four-phase plan review (CEO, design, DX, eng)**
Generated: 2026-10-20
Supersedes v1: `docs/designs/kait2en-bluefin.md` (APPROVED 2026-10-20), which stays as the record.
Reviews applied: `docs/reviews/01-ceo.md`, `docs/reviews/02-design.md`, `docs/reviews/03-dx.md`,
`docs/reviews/04-eng.md`. Where v2 differs from v1, the reviews won unless their own evidence
contradicted them; the three places where it did are named at the end of §1.
Shipping name: `bluefin-t2`.

Six calls were closed by the author between the eng review and this document (validation cadence,
Secure Boot and rotation, the module-spec mechanism, the firmware crossing, the v1 product surfaces,
the device claim). They are recorded once in §6 and applied throughout; nothing here re-opens them.

---

## 1. What v1 got wrong

Corrections the reviews proved. Each is specific, and each has evidence a future session can re-run.

| # | v1 said | What is true | Evidence | Fixed in |
|---|---|---|---|---|
| 1 | The firmware carrier is "`/boot/efi/kait2en/firmware/` on the installed ESP, written by the kit" (`kait2en-bluefin.md:369-370`) | Nothing the kit places in the live environment reaches the installed system. The kit runs on macOS and never touches the target disk; the live staging path is `/run`, which survives switch-root for the live session only | `research/KaiT2en-Fedora/auto-installer/initramfs/90-kait2en-updates.sh:23` — "Nothing placed here reaches the installed system"; the firmware rides a second initramfs (`grub.cfg.in:14`), not the target | §5 A4, §6 R2-3 |
| 2 | "11 base args + `firmware_class.path`" (`:256`), and Tier 0 compares "the expected 12-argument list" (`:431`) | **13.** KAIT2EN appends twelve — ten in `ADD_ARGS` plus `initcall_blacklist` and `module_blacklist` — and `/proc/cmdline` on the target shows exactly those twelve. `firmware_class.path=/var/lib/firmware` is ours and is the thirteenth. Both v1 numbers were wrong | `scripts/fedora/install-kernel-args.sh:67-78` (ten), `:109` and `:124` (two appended), probe of `/proc/cmdline` on `MacBookPro16,2` | §6 kargs, §9 Tier 0 |
| 3 | `t2gmux` "is expected to load and stay unbound" on MacBookPro16,2 (`:192-193`, `:473-475`) | It is present in the image (`modinfo -n t2gmux` → `extra/t2gmux.ko.xz`) and **not loaded at all** — `lsmod` shows 17 of the 18. The loaded-but-unbound object is `hid_t2magicmouse` (refcount 0, no Magic Mouse paired). v1 had two categories where there are three | `lsmod` / `modinfo -n` on the target, 2026-10-20 | §4 per-model map, §5 boundaries |
| 4 | The live installer initramfs carries "`t2touchbar`" among five modules (`:333-336`) | `t2touchbar` is a DKMS package and source directory, not an object. It ships `t2hid.ko`. The five objects are `t2bce_dma t2bce_core t2bce_vhci t2hid hid_t2magicmouse` | `auto-installer/kmod-kait2en-input.spec:41` installs `modules/t2touchbar/t2hid.ko`; `auto-installer/initramfs/20-kait2en-input.sh.in:6` loads the five object names | §5 initramfs, §9 Tier 0 |
| 5 | `kait2en-touchid-bind.service` is conditioned on `ConditionPathExists=%h/.config/kait2en/touchid-bound` (`:284`) while the prose says it "runs once per user (marker …)" (`:302-305`) | The condition is inverted. `ConditionPathExists=` is true when the path exists, so on a fresh user the unit never runs, and after it has run it runs at every login forever. A user unit also cannot restart a system service | v1's own two statements, plus systemd's condition semantics | §6 R2-9 |
| 6 | "KAIT2EN has no `akmod-*` spec … no akmods anywhere" (`:170`), and `akmods --force` builds the twelve specs | `ublue-os/akmods` contains **zero kmod specs** — its only three specs are addon packages — and every kmod it builds is an `akmod-*` RPM fetched from COPR, Terra or negativo17. The one worked kmod spec in reach is KAIT2EN's `kmod-kait2en-input.spec`, built with `rpmbuild` against a fixed kver | `research/akmods/` spec inventory; `build_files/common/build-kmod-xpadneo.sh:11`; `kmod-kait2en-input.spec:15` | §6 decision 3, §14 T1 |
| 7 | Constraint 5: "an unloadable input module makes the machine unrecoverable by its owner" (`:81-83`) | The Apple firmware feeds GRUB its keyboard, so the boot menu still works with zero T2 modules: arrow keys and Enter select the previous deployment. Unrecoverable is narrower — a **fresh** install with no previous deployment, and LUKS before root | `auto-installer/grub.cfg.in:26-27` (GRUB gets keys, loses only Ctrl-X/F10) | §2 Constraint 5, §13 |
| 8 | v2's ACPI route is `rpm-ostree initramfs-etc --track` + `rpm-ostree initramfs --enable` (`:317-319`, `:519-520`) | That is an rpm-ostree mechanism on a bootc target. bootc builds the initramfs in the image and its per-machine surfaces are kernel args and loader entries, not initramfs content | `research/bluefin/build_files/base/19-initramfs.sh:7-9` | §6 ACPI |
| 9 | Tier 0 asserts the initramfs module list, in CI (`:416-417`) | dracut treats a missing `force_drivers` object as a warning and continues. A CI-only assertion lets an image with no keyboard at the LUKS prompt build green | dracut behaviour; the guarantee needs the check inside the build | §5 initramfs guarantee, §14 T5 |
| 10 | Build-only packages are installed and "erased before commit", asserted absent by RPM query (`:216-226`, `:421-424`) | An RPM-database query cannot prove the files are gone, and says nothing about a cargo registry, a `target/` tree or a fetched tarball. The split must be structural | v1's own assertion, which can only see the RPM database | §5 builder stage |
| 11 | Route 2 is "`sudo bootc switch … && sudo reboot` … one reboot on an external keyboard" (`:361-365`) | There is no enrolment step, and MOK enrolment is a shim-time pre-boot step: it must happen **before** the reboot that introduces the modules, or the new deployment's modules do not verify and its internal keyboard never arrives | §6 R2-7; no `mokutil` on route 2 anywhere in v1 | §6 R2-7, §7 route 2 |
| 12 | Tier 2's smoke test asserts the loaded set includes `t2gmux` (`:473-475`) | That assertion fails on the only validated model (see row 3). A test that cannot pass on the bench machine would have been read as a module bug | `lsmod` probe | §4, §9 Tier 2 |

### Two review statements v2 does not carry

**The `hci_bcm4377` board-table gap is not "for 15,4".** `04-eng.md:545` says the Bluetooth gap is
"for 15,4", citing `research/findings/kait2en.md:437-446`. The cited evidence says the opposite:
upstream's own README lists the kernel driver's recognised models as **`MacBookAir9,1`,
`MacBookPro15,4`, `MacBookPro16,3`**, and says any other model aborts before asking for firmware
(`auto-installer/README.md:49-55`, enforced at `install-bt-firmware.sh:84-93`). So 15,4 and 16,3 are
the *covered* models; 16,2 and 15,2 are the uncovered ones — and on 16,2 it does not matter at all,
because this machine has no BCM4377 PCIe Bluetooth function: `lspci -nn` shows only `14e4:4464`
(BCM4364 Wi-Fi), Bluetooth is the UART controller, needs no Apple firmware, and `hci0` exists. The
consequence for the product: **Bluetooth does not gate the 13-inch class.** It gates the Airs and
iMacs (which are deferred anyway) and it remains an unmeasured datum for 15,2 and for any model whose
Bluetooth is BCM4377-based. The findings file is internally inconsistent here — one sentence says the
table covers three named models, the next says the bench machine's firmware install is expected to be
refused — so v2 records the per-model Bluetooth state as **measured data in `models.d`, never prose**,
and the smoke test measures it.

**`firmware_class` is not absent from KAIT2EN; it is only never set.** `04-eng.md:438-440` says
`grep -rn firmware_class` over the KAIT2EN tree "returns nothing". It returns one hit:
`auto-installer/runtime/kait2en-live-diagnostics:213` reads
`/sys/module/firmware_class/parameters/path` as part of a diagnostic capture. The review's
conclusion stands — KAIT2EN never *sets* the parameter, so the thirteenth karg is ours — but the
grep claim is false as written, and a future session that re-runs it will find the hit.

A third, smaller one: `04-eng.md:732` asks for "three synthetic runs, one per branch", while its own
outcome table (`:391-398`) has four branches. v2 requires four (§9 Tier 2).

---

## 2. Problem statement, What Makes This Cool, Constraints, Premises

### Problem Statement

KAIT2EN-Fedora gives a T2 Mac a materially better Linux experience than anything else available:
suspend that works, a usable Touch Bar, working Touch ID, audio DSP, fan and power control.
Suspension is not folklore — this machine's journal records **30 `PM: suspend entry (deep)` /
`PM: suspend exit` pairs in 30 days**, including 04:26:00→04:38:01 and 04:53:04→05:01:48 on
2026-10-20. It achieves this by keeping Fedora's stock kernel and adding 12 DKMS source packages
(18 `.ko`), one out-of-tree patched `amdgpu`, ~28 packages, and a large userspace layer under
`/usr/local`.

Bluefin Classic is the desired desktop, but it is immutable: `/usr` is a signed OCI artifact, the
kernel comes from `ghcr.io/ublue-os/akmods` and is versionlocked, and nothing may be compiled on the
host. KAIT2EN's entire delivery mechanism is host mutation — `dkms build/install` into
`/usr/lib/modules`, `grubby` on the live bootloader, `dracut --force` on `/boot`, `systemctl enable`
into `/etc`. None of it works there.

There is exactly one T2-on-atomic project today, `kansei-os/t2-atomic`. It solves packaging by
replacing Bluefin's kernel with a `sharpenedblade/t2linux` COPR kernel, deleting Bluefin's akmods
first. It has no Touch Bar support at all, does not install `t2-touchid` on the Bluefin flavour, and
**masks `suspend.target` twice**. On the target hardware it has none of the three things that make
KAIT2EN worth using, and it is not a base to build on — it is a peer.

The gap is real, unbuilt by anyone, and its shape is: port a host-mutating hardware layer onto an
image-based OS while keeping the three behaviours that motivated it.

### What Makes This Cool

A T2 Mac becomes a first-class Bluefin machine: transactional updates, rollback when a kernel breaks
your keyboard, and sleep that works — the thing every other Linux-on-T2 user has given up on and
jokes about.

The second win is the install. Every existing atomic T2 image needs an external keyboard, an external
mouse and usually ethernet, because the installer environment has no T2 drivers. KAIT2EN solved that
without rebuilding the ISO: five input objects in a second initramfs on the ESP plus a GRUB entry.
That trick is the most under-appreciated asset in the project, and it is what turns this from a
variant into a product.

The third, quieter win: firmware handling that respects the licence boundary instead of committing a
proprietary tarball to a public repo, while still being two clicks for the user.

The fourth, which v1 did not have: **the machine tells you what works.** One command, one window, the
same assertions the bench runs — so "it worked yesterday" arrives as evidence, and an unsupported
model is a named, bounded surprise rather than a bug report. That is the half of the product a person
actually experiences after the install ends, and it ships in v1.

### Constraints

1. **`/usr` is read-only and image-owned.** Nothing compiles modules, installs packages or writes
   `/usr/share` at runtime.
2. **Kernel and modules are locked together, and there are three kernels in play.** Bluefin erases
   the base kernel, installs the one from `ghcr.io/ublue-os/akmods:<flavor>-<fedora>-<kver>`, and
   versionlocks it. Bluefin `stable` labels `7.2.5-200.fc44.x86_64`; this host runs
   `7.2.11-200.fc44.x86_64`; the kit's transition kmod is pinned to the ISO's kernel,
   `6.19.10-300.fc44.x86_64` (`auto-installer/targets/fedora-44.conf:8`). A module built for any
   other release fails on vermagic. The image kernel is a container-only build; the host kernel is
   for Tier 1 only.
3. **Apple firmware is per-machine and non-redistributable.** Read from the running macOS at
   `/usr/share/firmware/wifi/{*.trx,*.clmb,*.txcb,P-*.txt}`; KAIT2EN explicitly refuses the
   redistribution packages. Verified: the four installed `brcmfmac4364b3-pcie.apple,trinidad-*`
   files are owned by no package, and Fedora's `linux-firmware` + `brcmfmac-firmware` contain zero
   Apple firmware files. **Corrected by review:** this payload cannot reach the installed system from
   the live environment, so the install has to carry it across (§6 R2-3).
4. **The build host is not a T2 Mac.** Every DMI/PCI gate in KAIT2EN's installer silently takes the
   "not my model" branch in a container. Gates move to runtime or to the supported-model data. The
   one narrow exception is a *single module* built on a T2 Mac against its own kernel for Tier 1
   (§9), which is what the author's machine already does as normal operation.
5. **Secure Boot must not be silently unsolved — and "unrecoverable" was the wrong word.** An
   unloadable input module means the new deployment cannot pass the LUKS prompt. It is
   **recoverable**: Apple's firmware gives the GRUB menu its keyboard, so the previous deployment is
   selectable with arrow keys and Enter. It is genuinely unrecoverable only on a fresh install with
   no previous deployment — which is precisely why enrolment happens in the live environment on
   route 1 and before the switch on route 2.
6. **KAIT2EN is not an upstream target for drive-by AI patches.** Its `README.md` says it will reject
   PRs and issues when it notices AI involvement and asks to be talked to in person. This project
   consumes KAIT2EN; it does not open PRs against it.
7. **KAIT2EN's trademark policy binds the shipping name.** `TRADEMARK.md` grants factual reference
   ("based on, compatible with, derived from KAIT2EN") but requires permission to use the name for a
   fork, distribution, product or service. See §8.
8. **Build cost:** 45–70 minutes and 20 GB+ disk for an image (two pulls of the same base plus
   10–25 minutes of Rust builds); the full loop including an ISO build and a Tier 3 run is a working
   day. This bounds iteration, and it is why the first task is not an image build.

### Premises

1. KAIT2EN's code ports; its mechanism does not. DKMS becomes prebuilt signed kmods.
2. Bluefin has no T2 support to extend. `t2-atomic-bluefin` is a peer image, not a base.
3. The published image cannot contain Apple firmware.
4. Reuse ublue's akmods *pattern* — kernel and module artifacts built together, tagged by kver,
   cosign-signed. **Corrected by review:** the pattern is not "specs in the akmods tree". akmods
   contains zero kmod specs, so the packaging is ours and only the publishing shape is inherited.
5. Secure Boot is a fork in the road, not a detail. v1 signs, enrols, and dual-signs across key
   rotation.
6. The image build does not belong on the Mac. A single module for Tier 1 does.
7. The capability layer is already model-generic; only the release claim was narrow. The four-model
   class claim is therefore a claim about evidence, not about engineering (§4).
8. One assertion set, several front ends: the same named assertions feed `bluefin-t2 report`, the
   hub's Overview, the HIL smoke test, the bug-report template and `MODELS.md`. Anything asserted in
   one place is asserted from one source.

---

## 3. Author's scope intent

Recorded 2026-10-20 after approval, carried into v2 with the claim widened by decision 6.

- The product is a **solid, usable workstation system for T2 MacBooks generally, especially the Intel
  models Apple no longer supports** — not a fix for one machine. That intent now has a scope that
  matches it: the four 13-inch, integrated-GPU, Touch Bar T2 MacBook Pros are the product, with the
  evidence tier stated per model (§4). Everything outside that class is deferred with a reason, not
  left implicit.
- Bluefin **Dakota** and **Utah** are on the upstream roadmap. **Forwards compatibility with them is
  a desired bonus, not a requirement.** Classic is the target. No v1 decision may depend on Dakota or
  Utah timelines, and no v1 work should make a later port structurally impossible — the `akmods-t2`
  split and the `FROM`-derivative shape both survive a base-image change, which is the cheapest
  forward compatibility available.
- The product's public claim and its evidence are allowed to differ **in tier, never in silence**:
  a model is either validated with a recorded run, or supported by a written argument the user can
  read on the machine, or out of scope with a stated reason. There is no fourth state.

---

## 4. Supported models

The claim is a **device class**: the four 13-inch, integrated-GPU, Touch Bar T2 MacBook Pros.
Labelling is by evidence: a model is **validated** once a digest-pinned Tier 2 result for *that* model
is recorded, **supported by argument** when only the four-part argument below covers it, and the
argument is written down here and shipped on the machine as `MODELS.md`. The claim covers four
models either way; only the evidence tier differs.

| Tier | Models | Basis |
|---|---|---|
| **Validated on hardware — run recorded** | `MacBookPro16,2` | The bench machine. A model enters this tier only by a digest-pinned Tier 2 result for that model (§9) — never by sharing code with one that passed. At generation this is the only recorded row |
| **Validated on hardware — run pending** | `MacBookPro15,2`, `MacBookPro15,4` | Decision 6's validation set. Both are class-A machines the author validates on; each carries a published claim only once its own digest-pinned Tier 2 run is recorded, which is open question 3 |
| **Supported by argument** | `MacBookPro16,3` | The four-part argument below and nothing else. Same code path, no measurement, and the machine says so |
| **Deferred — class B (dGPU)** | `MacBookPro15,1`, `15,3`, `16,1`, `16,4` | Need the patched `amdgpu` (11 patches to track per kernel), `t2gmux` wiring, the hybrid/dGPU apps, and the 16,1 kernel-arg exception — a *mechanism* v1 does not have (see the kargs resolution), not merely a model list |
| **Deferred — other machine class** | `MacBookAir8,1`, `8,2`, `9,1`, `iMac20,1`, `iMacPro1,1` | No Touch Bar; the iMac ASPM exception (`install-kernel-args.sh:84-92`); suspend/RTC parity unproven off-portable; the Airs' Bluetooth board-table question is an upstream-kernel question |
| **Out of product** | `MacBookPro13,x` and earlier, `MacPro*`, `Macmini*` | No T2. The product's own boundary |

### The four-part argument for the 13-inch class

Each part is from the evidence base, not analogy, and each is a condition a new model must satisfy —
which is why the same text is the contributor's add-a-model rubric.

1. **Same GPU class, therefore the same module set.** KAIT2EN's patched-`amdgpu` step is gated to
   `MacBookPro15,1|MacBookPro16,1|MacBookPro16,4|iMac20,1|iMac20,2` and exits early otherwise
   (`research/findings/kait2en.md:157-158`). All four 13-inch models are outside that list, so on all
   four the dGPU story is "no device".
2. **Same Touch Bar class, and the gate is already written as a class.** KAIT2EN's predicate is
   `MacBookPro15,* || MacBookPro16,*`, with the comment that every T2 MacBook Pro has a bar and the
   Air, mini, iMac and Mac Pro do not
   (`research/KaiT2en-Fedora/scripts/fedora/lib.sh:126-133`). Our only runtime gate is a device-node
   condition on the t2bdrm DRM node, so it needs no DMI read at all.
3. **Audio needs no per-model work.** KAIT2EN ships a DSP profile for every model in
   `MacBookPro15,x`/`16,x`, selected by udev from DMI at runtime, with no install-time PCI detection;
   unsupported models simply receive no graph (`dsp/config/models.json` — 13 entries, including all
   four class-A models; `dsp/README.md:16-23`). All profiles ship in the image, so 15,2/15,4/16,3
   get correct audio without new work.
4. **No kernel-arg exception applies to any of them.** The complete upstream exception set is `iMac*`
   (ASPM breaks the Ethernet controller) and `MacBookPro16,1` (Navi 14 drops off the bus), at
   `scripts/fedora/install-kernel-args.sh:80-116`. No 13-inch model matches either branch.

Firmware does not enter the argument, and that is the point: the kit derives filenames from what the
kernel asked for at runtime, so the firmware channel is per-machine by necessity and model-generic
for free. **Corollary from the correction in §1:** Bluetooth does not enter it either. Every class-A
model either has no BCM4377 PCIe Bluetooth function (verified on 16,2: `14e4:4464` only, UART
Bluetooth, `hci0` present) or is one of the three models the kernel's board table does cover
(`auto-installer/README.md:49-55`). 15,2's Bluetooth is the one unmeasured case and it is measured by
the Tier 2 smoke test, not asserted here.

### Per-model expected-absent map

Data, not prose: one TOML per supported model at `/usr/share/bluefin-t2/models.d/<ProductName>.toml`,
consumed by `bluefin-t2 report`, the hub, Tier 2 and `MODELS.md` (one expectation set, four
consumers). Three categories, because two were not enough:

| Category | Meaning | On `MacBookPro16,2` (probed) |
|---|---|---|
| `expected_loaded` | object loads and binds (or is a legitimate no-device load) | 16 of 18: `t2bce_dma t2bce_core t2bce_vhci t2bce_audio t2bce_ave t2hid t2touchbar_bl t2touchbar_kbd t2bdrm t2smc t2smp t2sbs t2thunderbolt t2mfi_fastcharge t2_precision_trackpad t2_trackpad_actuator` |
| `expected_unbound` | object loads, no device binds it | `hid_t2magicmouse` (refcount 0 — no Magic Mouse paired) |
| `expected_absent` | present in the image, correctly not loaded on this model | `t2gmux` — no GPU mux device on a 13-inch integrated-GPU model |

For 15,2/15,4/16,3 the file starts from 16,2's set with the two measured exceptions replaced by
"unmeasured" until the model is run; the report prints `untested`, never `working`, for anything a
model's file does not claim. `t2sep` is a latent nineteenth object: `modules/t2sep/dkms.conf` exists
in the KAIT2EN tree, `modinfo t2sep` returns "not found", and it is not one of the 12 registered
packages. It stays out, and the named-set style is what makes that safe (§9).

---

## 5. The locked architecture

Four published artifacts, one build host, one HIL bench, one harness image. The additions from the
reviews change what artifact 2 contains and add data files; they do not add an artifact.

```
  ublue akmods ──(label ostree.linux=KVER)──► [A1] akmods-t2 ──(kmods for exactly KVER)──┐
                                                                                          ▼
  bluefin:<fedora>@<digest> ──(label ostree.linux=KVER)───────────────────────────► [A2] bluefin-t2
                                                                                          │
                                                       [A4] BIB anaconda-iso ◄────────────┘
                                                             │  + post-script inside inst.updates
  [A3] kit (macOS: captures the firmware, writes the USB) ◄──┘
        │  ISO + firmware payload on the stick
        ▼
  install A2 on the target ──► [HIL] results on a separate USB stick
```

**Kernel resolution, one direction only.** `KVER` for A2 is read from the *pinned base digest's*
`ostree.linux` label — never `uname -r`, never a floating tag, never the akmods image. That is
Bluefin's own rule: it reads the label (`research/bluefin/Justfile:153`), verifies the kver-tagged
image (`:159`), and writes the label at publish time (`:219`). A1 resolves its `KVER` from *ublue's*
floating akmods tag, which is the earliest point in the chain, so A1 can never be later than A2 by
construction.

**The tag is a name; the RPM dependency is the lock.** `skopeo inspect` on the kver tag is what gives
a clean, named error ("no kmod cache for 7.2.5-200.fc44"). What actually prevents a broken image is
upstream of it: every kmod RPM carries `Requires: kernel-core-uname-r = <KVER>`, exactly as
KAIT2EN's transition package does (`auto-installer/kmod-kait2en-input.spec:15`). With that
dependency a mismatch makes `dnf5 install` fail even if the tag check were deleted. Assert it with
`rpm -qpR` in A1's Tier 0, and the race stops being a policy and becomes a property.

### Artifact 2's final stage, nine steps

Two stages. The builder stage compiles and is discarded; nothing it touched exists in the image.

```
FROM ghcr.io/ublue-os/bluefin:<fedora>@<digest> AS t2build      # builder: compiles only
  B1  dnf5 install build-only set: cargo rust gtk4-devel libadwaita-devel libinput-devel
      libplist-devel systemd-devel glib2-devel rpm-build pkgconf-pkg-config gcc make
      checkpolicy policycoreutils selinux-policy-devel
  B2  COPY the pinned KAIT2EN submodule
  B3  build 8 apps + t2remote → /out/rpms/*.rpm
  B4  checkmodule + semodule_package → /out/selinux/*.pp
  # nothing from this stage reaches the image except /out

FROM ghcr.io/ublue-os/bluefin:<fedora>@<digest>                # the image, nine steps
  01  resolve KVER from the pinned digest's ostree.linux; skopeo copy + cosign verify the kver tag;
      unpack; dnf5 install the kmod RPMs; depmod -a "$KVER"; write modules-load.d + modprobe.d
  02  dnf5 install the runtime set; rsync system_files/shared/ /
  03  dnf5 install /out/rpms/*.rpm  (the 8 apps, t2remote, the hub, the report)
  04  semodule -X 400 -i /out/selinux/*.pp ; authselect select … with-fingerprint
  05  fc-cache -f ; gtk-update-icon-cache ; dconf update        ← after every file is in place
  06  dracut --force --no-hostonly --kver "$KVER" --reproducible --add ostree
  07  90-tests.sh  (our gates; Bluefin's 20-tests.sh is not ours and does not run here)
  08  bootc container lint                                      (last, as Bluefin does)
  09  publish asserts: labels + digest + cosign + image-size delta ≤250 MB  (CI, not Containerfile)
```

Two orderings here are load-bearing and both differ from v1. **Cache generation moved from v1's step
08 to step 05**, because v1 ran `fc-cache`/`gtk-update-icon-cache` before the policy install and
before the hub's dconf entries existed. **`90-tests.sh` runs `lsinitrd`**, because that is the only
place the initramfs guarantee is a proof (below).

### The initramfs guarantee, stated exactly

**(Corrected 2026-10-22 by the executable config.)** The six objects actually forced are
`t2bce_dma t2bce_core t2bce_vhci t2hid t2smc t2sbs` — the same list as the KaiT2EN host's
`/etc/dracut.conf.d/90-kait2en-input.conf`. `hid_t2magicmouse` is **not** one of them; it loads
with the internal trackpad's USB enumeration (36 s after multi-user on the 14:04 boot) and the
smoke test now waits for it instead of sampling once. The five-object list above was v1's,
carried into v2 without checking the host file.


The keyboard before root is guaranteed by four things, and only the fourth is a proof:

1. `usr/lib/dracut/dracut.conf.d/90-t2-input.conf` ships in the image, copied verbatim from the live
   host's `/etc/dracut.conf.d/90-kait2en-input.conf`:
   `force_drivers+=" t2bce_dma t2bce_core t2bce_vhci t2hid t2smc t2sbs "` — six objects
   (`scripts/fedora/rebuild-initramfs.sh:17-23`, verified against the file on the target).
2. The six objects are installed under `/usr/lib/modules/$KVER/` by step 01, before dracut runs.
3. `dracut --no-hostonly --kver "$KVER" --add ostree -f` runs at step 06, as Bluefin does
   (`research/bluefin/build_files/base/19-initramfs.sh:7-9`).
4. `90-tests.sh` runs `lsinitrd` and asserts each of the six names is present **inside the build**.
   This is the proof: dracut warns and continues on a missing `force_drivers` object, so a typo, a
   renamed module or a stale path otherwise produces a green build and a machine with no keyboard at
   the LUKS prompt.

Fallback when a kernel bump breaks a module: the compile fails in A1, no tag is published for the new
`KVER`, A2's tag check fails with a named error, no image is published, users stay on their previous
deployment. That chain is the project's real safety property and it only exists once the tag check
and the RPM dependency are both in place.

### Signing key lifecycle, locked

| Stage | Decision |
|---|---|
| Generation | Offline, one keypair, `signing_key.pem` (private key + cert concatenated, `dual-sign.sh`'s format); public DER committed, shipped at `/etc/pki/akmods/certs/` and published as a release asset for `mokutil --import` |
| CI storage | Organisation secret, available only to `push`-on-`main`/tag workflows. Fork PRs cannot sign — GitHub does not expose secrets to them — so contributor PRs build with the test keys already in `research/akmods/certs/` and only releases are signed with the real key. "Verify the signature" in a PR therefore means "against the test key", and that is stated in `CONTRIBUTING.md` |
| Shipping | DER at `/etc/pki/akmods/certs/` (the `ublue-os-akmods-addons` convention) plus a release asset |
| Rotation | **Additive and overlapping** (decision 2): a second key signs every module **twice** for at least two releases after a rotation — two `-signer` arguments in one CMS invocation, which is exactly what `dual-sign.sh:19-21` does. Single-sign outside rotation windows. v1's "no reason to dual-sign" (`:194-205`) was right about the kernel (we do not hold the kernel key) and wrong about rotation |
| Existing users during rotation | Nothing breaks during the overlap. After it, a user who never enrolled the new key loses the modules on the next upgrade; recovery is the GRUB menu and a rollback, not a reinstall, because Apple firmware still feeds GRUB its keyboard |
| Detection | `bluefin-t2 report` asserts `mokutil --sb-state` and whether our DER is in the enrolled list, and exits 1 with the enrolment command. Without it the failure is silent until a keyboard does not work |
| Drill | T15, once per rotation, not per release |

### Artifact boundaries, including everything the reviews added

| Thing | Lives in | Build cost | Asserted by |
|---|---|---|---|
| 12 kmod specs, 18 objects, signing | **A1** | 15–40 min per kver — the largest estimate line | A1 Tier 0: build, sign, verify, `rpm -qpR` |
| Kernel + module lockstep | **A2** step 01 | one skopeo + cosign per build | Tier 0 tag-absence negative test |
| 6 initramfs objects | **A2** step 06 | one dracut pass, 60–120 s | `lsinitrd` in `90-tests.sh` (step 07) |
| SELinux module + PAM feature | **A2** step 04 (policy built in B4) | seconds | `semanage module -l`; PAM stack grep |
| 8 apps + `t2remote` | **A2** step 03 (built B1–B3) | +10–25 min, +60–120 MB compressed | `desktop-file-validate`, `appstreamcli`, `ldd` closure |
| Hub app `bluefin-t2` | **A2** step 03, one more RPM | ~200–400 LOC Rust, +5–10 MB | desktop entry valid; it reads `report --json`, never the human format |
| `bluefin-t2 report` | **A2** image and **A1 harness** (same source, built once) | one binary, no new infra | Tier 0 fixtures for exit 0/1/2; Tier 2 on hardware; Tier 3 for the absent-payload state |
| First-login provisioning | **A2** one user unit + one helper + one marker | negligible — it is the same event as the Touch ID bind | unit verify; Tier 2 once-only |
| `MODELS.md`, `RECOVERY.md` | **A2** `/usr/share/bluefin-t2/` | 2 files | presence + non-empty |
| Per-model expectation data | **A2** `/usr/share/bluefin-t2/models.d/<ProductName>.toml` | 4 small TOMLs | one schema test; consumed by four front ends |
| Firmware payload | **A3** kit → target ESP via A4 | under 1 MB | Tier 3 asserts presence before first boot |
| Post-script | **A4**, inside the kit's `updates.img` | seconds | Tier 3 only |
| Harness-only units, `attempt.json`, `stages.log`, results | harness image + results stick | none in the release image | the HIL run itself |

Two boundary decisions follow. **One harness image, not two:** `akmods-t2:harness` is published from
A1's own build container — it already has `kernel-devel` at the right kver because it compiles the
modules — so Tier 0 runs there against the built image mounted read-only, and the harness can never
drift from the kernel it tests. **One expectation set, three consumers** (§4), extended to four by
the bug-report template.

---

## 6. Resolutions

### The six closed calls

| # | Decision | Where it lands |
|---|---|---|
| 1 | **Validation cadence: per-release gating, not per-image** — and the harness records its own wall clock, so the number is measured, not argued | §9 Tier 2, §13 |
| 2 | **Secure Boot v1: sign and enrol, with dual-sign across a two-release overlap**; single-sign outside rotation windows | §5 lifecycle, §6 R2-7, §14 T15 |
| 3 | **Module spec mechanism: the `rpmbuild` template for the contributor loop; `akmods --force` for the published artifact** — both documented, with which to run when | §10 contributor on-ramp, §14 T1/T2 |
| 4 | **Firmware crossing: the Anaconda post-script inside the `updates.img` the kit already ships**, with a kickstart `%post` as the documented fallback decided at the first ISO build | §6 R2-3, §14 T8/T13 |
| 5 | **Product surfaces ship in v1:** the hub (`bluefin-t2`, six inherited entries set `NoDisplay=true`, launched unchanged), `bluefin-t2 report` (report-only, no upload ever), and the first-login surface that opens only when something is not OK | §7, §14 T10/T11 |
| 6 | **Device claim: the four 13-inch integrated-GPU Touch Bar models** — 15,2 / 15,4 / 16,2 validated on hardware, 16,3 supported by the written argument; class B, the Airs, the iMacs and iMac Pro deferred with reasons | §4, which states each model's evidence status |

### R2-13 — the two-pipeline race

**Decision.** `KVER` is read from the pinned base image's `ostree.linux` label *before* the `FROM`;
`akmods-t2` publishes a floating `<flavor>-<fedora>` tag and the immutable `<flavor>-<fedora>-<KVER>`
tag, each carrying `ostree.linux`; A2 verifies the immutable tag with cosign and fails with a named
error when it is absent; every kmod RPM carries `Requires: kernel-core-uname-r = <KVER>` so a
mismatch cannot install; A1 resolves `KVER` from *ublue's* floating akmods tag, never from
`bluefin:stable`, because Bluefin publishes only after ublue's akmods moves and chasing Bluefin's
label would put A1 a day behind reality.

**Trigger order.** (1) ublue akmods publishes its floating and kver tags. (2) A1 runs: daily cron on
ublue's label, `repository_dispatch` on KAIT2EN movement, manual. (3) Bluefin publishes. (4) A2 runs
on cron against Bluefin, or on dispatch from A1. Steps 2 and 3 run concurrently and step 4 can start
before step 2 finishes — that is fine, because step 4 fails closed. No ordering discipline is
required, which is the point: order is a weaker guarantee than a check.

**Tested by.** A2 Tier 0 negative test: run step 01 with a `KVER` for which no tag exists, assert a
nonzero exit and the exact error text. A1 Tier 0: `rpm -qpR` on all 12 RPMs. A second negative test
forces a wrong-kver RPM into the unpack directory and asserts the install fails.

### R2-3 — firmware across the install boundary

**Decision (closed call 4).** The payload crosses in the **Anaconda installer environment**, because
the kit runs on macOS and never touches the target disk. Three parts:

1. **The carrier already exists.** The kit writes the firmware as a second initramfs image
   (`auto-installer/grub.cfg.in:14-15` lists the ISO initrd plus `kait2en-input-initramfs.img` and
   `kait2en-wifi-initramfs.img`), and a dracut pre-pivot hook copies it to
   `/run/kait2en/apple-firmware` (`auto-installer/initramfs/90-kait2en-updates.sh:4,14-25`). That
   hook's own comment says `/run` survives switch-root for the live session only — "Nothing placed
   here reaches the installed system" (`:23`). So during the install the four files sit at a known
   absolute path in the installer root.
2. **The transfer is one post-script inside the updates image the kit already ships.** Add
   `/usr/share/anaconda/post-scripts/90-bluefin-t2-firmware.ks` to that image. It copies
   `/run/kait2en/apple-firmware/*` to `/mnt/sysroot/boot/efi/kait2en/firmware/wifi/`, verifies
   `SHA256SUMS`, checks free space on the **target** ESP, and writes
   `/mnt/sysroot/etc/bluefin-t2/firmware-import.json` with the captured chip and board. No
   `inst.ks=`, no Anaconda Python addon, no new cmdline, and the kit's own self-checks
   (`build-in-container.sh:332,334`: `inst.updates` present, `inst.ks=` absent) stay true.
3. **Fail closed.** The post-script runs `--erroronfail`. If the source exists and the copy or the
   checksum fails, the installation fails while the cause is still on screen, instead of producing a
   machine with no Wi-Fi and no explanation. If the source is absent (route 2, or an unprepped ISO),
   the install proceeds and first boot reports `absent`.

**Why not the alternatives.** A kickstart `%post` from a BIB
`[customizations.installer.kickstart]` block also works and is proven in this evidence base
(`research/t2-atomic/disk_config/iso-bluefin.toml:1-5`), but it puts the transfer code in the ISO, so
every copy fix costs an ISO rebuild and a Tier 3 run. A first-boot copy from the install medium
requires the USB to stay attached at first boot, which re-introduces the external-hardware
dependence route 1 exists to remove. Reflowing the target ESP from macOS is impossible: the target
ESP does not exist yet.

**The one thing not proven.** Whether this Anaconda version executes `updates.img` `post-scripts`.
It is a documented mechanism, unproven in this tree, and it is open question 2 (§12). Tier 3 is the
test; the fallback is the kickstart block, decided at the first ISO build, not at release.

**Tested by.** Tier 3 and only Tier 3: after the install completes and before first boot, mount the
target ESP and assert the four files, `SHA256SUMS` and `firmware-import.json`; then boot and assert
Wi-Fi associates. A negative Tier 3 run deletes the payload mid-install and asserts the install fails
with the named message.

### R2-7 and route 2 — enrolment before the switch

**Decision.** Route 2 gets a mandatory enrolment step **before** the switch, on the running stock
Bluefin with the external keyboard attached: download the DER, `mokutil --import`, reboot, enrol in
the MOK Manager, then `bootc switch`.

**Why the order is the mechanism.** `bootc switch` changes the deployment and reboots; there is no
pre-boot hook, and the new deployment — the one whose modules need the key — cannot enrol anything
because it cannot start. MOK enrolment is a shim-time, pre-boot, interactive step, so it must be
staged before the reboot that introduces the modules. The user is already on an external keyboard on
stock Bluefin, so the keyboard requirement is not new; the failure being prevented is the one where
they put it away after the reboot.

**Recovery, and the corrected hazard model.** Per Constraint 5 and §1 row 7: the new deployment is
unbootable past the LUKS prompt, and the machine is recoverable from the GRUB menu by choosing the
previous deployment. That recovery is a shipped procedure (`RECOVERY.md`) and a line in
`bluefin-t2 report`, not prose in a design document. What is genuinely unrecoverable is a fresh
install with no previous deployment — which is why enrolment happens in the live environment on
route 1 and before the switch on route 2.

**Tested by.** Tier 3 for route 1 states (b) and the deliberately-skipped state (c), with the
boot-menu rollback executed and recorded. Route 2 is a scripted procedure on a stock Bluefin T2
machine, once per release cycle.

### R2-9 — the Touch ID bind unit, the inverted condition, one helper

**Decision.** One user unit for all per-user provisioning, the condition fixed, exactly one
privileged helper.

```
/etc/systemd/user/bluefin-t2-first-login.service
  [Unit]
    Description=bluefin-t2 first-login provisioning
    # Conditions are [Unit] keys. Under [Service] systemd reports
    # "Unknown key ... ignoring" and the unit runs unconditioned.
    ConditionPathExists=!%h/.config/bluefin-t2/provisioned     # note the "!"
    ConditionUser=!@system
  [Service]
    Type=oneshot
    ExecStart=/usr/bin/pkexec /usr/libexec/bluefin-t2/provision-user
    RemainAfterExit=yes
  [Install]
    WantedBy=default.target
```

- **The inversion.** `ConditionPathExists=` is true when the path exists. v1 conditioned on the
  marker the unit itself creates, so on a fresh user it was false and the unit never ran, and after
  one run it was true and ran at every login forever. `ConditionPathExists=!` is the primitive: run
  while the marker is absent, create it, stop. `ConditionUser=!@system` keeps it out of the
  greeter's session. It is idempotent, and re-runs if the user deletes the marker, which is the
  behaviour we want. Every other new condition was checked against the same rule.
  **(Corrected 2026-10-21 while building the unit: conditions are `[Unit]` keys. This block
  originally showed them under `[Service]`, where systemd ignores them with `Unknown key …
  ignoring` — which silently restores exactly the defect above. The shipped unit has them under
  `[Unit]`, and Tier 0 asserts it. The Touch Bar attach unit does not condition on a device node;
  see "The other inverted conditions".)**
- **The helper.** `/usr/libexec/bluefin-t2/provision-user`, shipped with
  `/usr/share/polkit-1/actions/org.bluefin_t2.provision-user.policy`, action
  `org.bluefin_t2.provision-user`, `allow_active=yes`, and **no user argument**: it derives the uid
  from `PKEXEC_UID`, so it can only ever provision the caller. It does three idempotent things:
  writes `T2_TOUCHID_BIND_USER=<caller>` into `/etc/kait2en/t2-touchid.conf` and restarts
  `kait2en-t2-touchid.service` only if the value changed; runs
  `usermod -aG kait2en-touchbar <caller>` (the second per-user need, same helper, same event); and
  creates the marker as the caller. `allow_active=yes` is right rather than `auth_admin`: binding
  your own account is self-service, not privilege escalation, and a polkit prompt from a background
  user unit has no agent in general. The security property is the absent argument, not the
  authentication.
- **Not a second mechanism.** The Touch ID binding, the Touch Bar group and the first-login report
  are one unit, one helper, one marker. Two markers and two helpers for one event is the duplication
  the CEO review already rejected.

**Corrected 2026-10-22, from Tier 2 evidence.** This decision did not survive a real login. A
`systemd --user` service is not a logind session, so `allow_active=yes` never applied: the
greeter's attempt failed on `SHELL … not in /etc/shells`, and the real user's attempt was
refused `Not authorized` (`docs/evidence/tier2-run-2026-10-22.md` carries the journal). The
group was never added, so the Touch Bar daemon could not open its devices until it was done
by hand.

The replacement is a root **system** service with no privilege boundary to cross:

```
/usr/lib/systemd/system/bluefin-t2-user-groups.service   # oneshot, ExecStart=user-groups
/usr/lib/systemd/system/bluefin-t2-user-groups.path      # PathChanged=/etc/passwd
/usr/libexec/bluefin-t2/user-groups                      # root; --dry-run for tests
```

It adds every human account (uid 1000–59999, shell not `nologin`/`false`) to
`kait2en-touchbar`, and sets `T2_TOUCHID_BIND_USER` to the first such account when the shipped
config still says `none`. The path unit is what catches the account gnome-initial-setup creates
after `multi-user.target`, which a boot-time oneshot cannot see. The user unit, its marker, the
polkit action and the pkexec helper are removed; Tier 0 asserts no runtime surface invokes
pkexec. Provisioning is idempotent state now, not an event that needs a "done" flag.

**Tested by (as corrected 2026-10-22).** Tier 0: the five named units verify; `user-groups` is
0755, not setuid, and `--dry-run` against a fixture `/etc/passwd` names the human account and
skips system ones; no runtime unit or helper invokes pkexec; the path unit names the service and
watches `/etc/passwd`; the enable symlinks and preset lines agree. Tier 2: a fresh user's first
login leaves them in `kait2en-touchbar`, and `T2_TOUCHID_BIND_USER` names them; `systemctl
--failed` is empty.

### R2-11 — failed-boot capture

**Decision.** Three monotone artifacts, each written by a different layer, so the *absence* of the
next one localises the failure:

| Artifact | Written by | When | Proves |
|---|---|---|---|
| `attempt.json` (digest, KVER, SB state, boot target, timeout, run id) | **host harness**, onto the results stick | before the machine is powered on | the run existed |
| `stages.log` (one appended, fsync'd line per stage) | `bluefin-t2-hil-early.service` at `sysinit.target`, then `bluefin-t2-hil-userspace.service` at `multi-user.target` | during boot | the kernel and initramfs completed; userspace reached the stage |
| `result.json` (the smoke test) | `bluefin-t2-hil-test.service`, which then powers off | after the smoke test | the run finished, and with what outcome |

Outcomes, evaluated by the **host** on the next run, because a machine cannot report its own
pre-Linux failure:

1. `attempt.json` + `stages.log` (2 lines) + `result.json` → pass or fail, from `result.json`.
2. `attempt.json` + `stages.log` (1 line), no `result.json` → `FAILED_USERSPACE`, with the stage name.
3. `attempt.json`, no `stages.log` → `FAILED_BOOT`. This is the branch v1 was missing: a failure in
   the kernel or initramfs, exactly the class the marker was supposed to catch. The host writes the
   record with the digest, the timeout and a **required** `photograph` field, and refuses to close the
   run until the path is filled in.
4. No `attempt.json` → `HARNESS_ERROR`.

A `sysinit.target` unit cannot observe an initramfs failure, and neither can anything else inside the
failing kernel — only a writer outside the machine, before the attempt, can cover that class, and only
a stage log inside the machine can split "kernel died" from "userspace died". A T2 Mac has no serial
console, so the photograph is the capture path for case 3, and it is a field in the record rather
than an operator habit. v1's separate harness "capture" unit is gone: the host writes that record.

### The other inverted conditions and the unit logic

Three conditions to check and one duplicate, beyond R2-9:

- `kait2en-touchbar-attach.service`: it carries **no** `ConditionPathExists`. Its guard is
  `ExecCondition=/usr/bin/systemctl --global is-enabled --quiet kait2en-touchbar.service`, which is
  correct for its purpose: after `systemctl --global disable kait2en-touchbar.service` the next boot
  keeps Apple's firmware row instead of attaching a panel nothing will drive. Absence of the device
  is the daemon's own failure (`--attach` fails, and `Restart=on-failure` is bounded). An earlier
  revision of this paragraph said the unit conditioned on the t2bdrm DRM node; the live unit and the
  pinned clone both say otherwise (checked 2026-10-21). Kept, name unchanged.
- `bluefin-t2-firmware-import.service`: v1 conditioned on
  `/boot/efi/kait2en/firmware/wifi` — correct direction, but a half-written payload would pass it.
  Condition instead on the **marker the writer creates**, `…/firmware/wifi/SHA256SUMS`, verified
  before use.
- `bluefin-t2-firmware-import.path`: v1 watched the same directory the service writes to, so it
  could re-trigger on its own output. It watches the **incoming** `SHA256SUMS`; the service removes
  nothing, copies to `/var/lib/firmware/brcm/`, and writes its state to
  `/var/lib/bluefin-t2/firmware.state`, outside the watched path.
- The first-login report and the Touch ID bind are the same event: one unit, one helper, one marker
  (R2-9), not two.

### The kargs set, named

**Decision.** v1 ships **13** arguments, as a named set, with no model exceptions; Phase 1's
four-model class needs none.

KAIT2EN's `ADD_ARGS` is ten entries (`install-kernel-args.sh:67-78`), then two more are appended
(`:109` `initcall_blacklist=…`, `:124` `module_blacklist=…`), so the live set is 12 — which
`/proc/cmdline` on the target confirms verbatim. `firmware_class.path=/var/lib/firmware` is **ours**:
KAIT2EN never sets it (it reads the parameter in one diagnostic,
`auto-installer/runtime/kait2en-live-diagnostics:213`), and the kernel parameter is real and empty on
the target (`/sys/module/firmware_class/parameters/path`). Total 13, not v1's "11 base args +
`firmware_class.path`" and not its "expected 12-argument list".

The shipped set, in order and diffable:
`amdgpu.aspm=1`, `i915.enable_guc=2`, `intel_iommu=on`, `iommu=pt`, `pm_async=off`,
`brcmfmac.p2pon=0`, `pcie_aspm=force`, `pcie_aspm.policy=powersave`, `pcie_ports=compat`,
`mem_sleep_default=deep`, `initcall_blacklist=cmos_init,magicmouse_driver_init`,
`module_blacklist=acpi_tad,applesmc,macsmc,hid_apple,hid_appletb_bl,hid_appletb_kbd,hid_magicmouse,appletbdrm,apple_bce,apple_mfi_fastcharge,apple_gmux,sbs`,
`firmware_class.path=/var/lib/firmware`.

Assert the named list; delete the count. A count assertion is the same defect v1 correctly rejected
for the 18 objects.

**Why no class-A model needs an exception.** The complete upstream exception set is `iMac*` (drop
`pcie_aspm=force`) and `MacBookPro16,1` (drop the AMDGPU and PCIe ASPM args), at
`install-kernel-args.sh:80-116`. No 13-inch model matches either branch. That is a fact about the
four models, which is why the class claim survives.

**How a per-model karg would ever work.** `/usr/lib/bootc/kargs.d/*.toml` is declarative and static:
applied at install and on upgrade while preserving machine-local args. There is no
`match-product-name` key. The paths are (a) ship the safe union and lose the ASPM benefit where it
matters, (b) a privileged first-boot writer that edits the deployment's local args and reboots,
guarded by bootc preserving machine-local args across upgrades, or (c) a per-model image variant,
which multiplies the build matrix. (b) is the v2 design, and its probe is "does a machine-local arg
survive `bootc upgrade`" on a throwaway install. Until that probe exists, class B is gated by a
**mechanism**, not by validation effort, and the design should say so.

### ACPI

**Decision.** v1 ignores ACPI entirely, and v2 must not plan on `rpm-ostree initramfs-etc --track`.

That was v1's v2 route and it is an rpm-ostree mechanism on a bootc target. On bootc there is no
rpm-ostree-managed initramfs pipeline: the initramfs is built in the image
(`19-initramfs.sh:7-9`), and bootc's documented per-machine surfaces are kernel args and loader
entries, not initramfs content. So the route as written is not a route. The honest options for
per-machine ACPI tables are (a) bake the known tables for known models into the image — which is
exactly what a supported-model list makes safe — or (b) find a bootc-supported early-userspace hook,
which needs a probe and may not exist. v1 costs nothing either way: no class-A model is recorded as
needing an ACPI override. Getting this wrong in v2 would produce a plan whose central mechanism does
not exist on the platform, discovered when a user's machine needs it.

### What the reviews' additions cost

| Addition | Lives in | Build cost | Asserted by |
|---|---|---|---|
| Device class (4 models, per-model data) | **A2** `models.d/*.toml` + `MODELS.md`; docs for the argument | 5 files, ~200 lines, no code path | Tier 0 presence + schema; Tier 2 reads the model under test's file |
| Hub app `bluefin-t2` | **A2** one RPM from the builder stage | ~200–400 LOC, +5–10 MB, one rebase surface (it must consume `report --json`) | `desktop-file-validate`, `appstreamcli`; Tier 2 "one icon, report content rendered" |
| `bluefin-t2 report` | **A2** image and **A1** harness, one build | one binary; the `--json` schema is the contract between report, hub and `result.json` | Tier 0 fixtures for 0/1/2; Tier 2; Tier 3 for absent payload |
| First-login surface | **A2** user unit + helper + marker | negligible, but it is the same event as the bind unit | unit verify; Tier 2 once-only |
| Builder stage | **A2** | two base pulls, no final-image cost | Tier 0 absence assertions, kept as defence in depth |
| `MODELS.md`, `RECOVERY.md` | **A2** `/usr/share/bluefin-t2/` | 2 files, written after the first green Tier 3 | presence + non-empty |

The framing change that makes all of this cheap: **the report is not a new subsystem.** It is the
assertion set the image already needs for its own Tier 2 and its own hub. Build it once, in the image,
and the HIL rig consumes the same binary from the harness tag.

### Taste calls the gauntlet did not name

Four remain from the reviews and are decided here, so nothing is left hanging. They are recorded with
their tradeoff because a future session may disagree with the call, not with the reasoning.

| Call | Decided | Why |
|---|---|---|
| Design T3 — Touch Bar dark-first or lit | **Dark-first kept**, with a first-run lesson and a one-tap "keep it lit" choice stored in the user config | Dark-first *is* the power feature and the learned timeout is the best interaction in the inherited design; the fix for "it looks broken" is teaching, not changing the default |
| Design T4 — unsupported model: soft verdict, hard gate, deny list | **Soft verdict** (report exit 2 + `MODELS.md`), no hard gate | A hard gate turns away a 15,2 owner whose machine very likely works, which is the one-machine port the reviews rejected; the deny list would need an owner per model |
| Design T5 — do the shipped apps take the product name | **Hub-only**: the product's name on the one surface we author; inherited app names untouched | Renaming forks six crates' branding from a pinned submodule and breaks every screenshot and doc for no user-visible gain |
| DX TD1 — cosign or `shasum` for the kit download | **`shasum -c` is the required check; cosign is published as the optional stronger one**, and every published artifact is cosign-signed | macOS ships `shasum` and not cosign; a check that runs beats a stronger check that is skipped. Provenance stays on the artifact, where it is enforced in CI |
| DX TD4 — may a T2 Mac be a build host | **Yes, narrowly**: a single module for Tier 1, with the page stating the vermagic will not match the image; the image kernel stays container-only | It doubles the contributor pool to include the people who own the hardware, and Tier 1 already assumes exactly that machine |

---

## 7. The user-facing product

### The install journey, end to end, with the G1–G7 fixes

Steps 2–5 run on macOS, 6–7 in the installer, 8–10 in the first session. Each step names what is
missing in v1 and what v2 ships instead.

1. **Choosing a route.** v1 gives a stranger no first question. v2 opens with it, in
   `docs/WILL-IT-WORK.md` and the kit's own `--help`: *does this Mac still boot macOS?* Yes → route 1.
   No → route 2, with its real preconditions stated up front (external keyboard, a USB stick with
   the firmware, the image reference) and a "keyboard needed until" column in the route table — the
   honest version of v1's "one reboot on an external keyboard". Route 1's macOS precondition is a
   supported-path condition, documented, with a "reinstall macOS first" page referenced from the
   kit's own die.
2. **Pre-flight on macOS.** The kit's Secure Boot advice is replaced (G2). It no longer says "No
   Security"; it says what this product does, per route, in two conditional blocks. The disk menu
   gains what the confirmation already assumes: media name, capacity, "3.1 GB needed / 64 GB
   available" per row, and a line saying this is not your boot disk.
3. **The typed wipe confirmation.** Kept exactly — `ERASE diskN`, a refusal that names the wanted
   phrase, a retry that names Ctrl-C. The one addition is context before it: the firmware captured so
   far and what the machine will gain.
4. **Firmware capture.** Kept, including the best message in the product ("Enable Wi-Fi, reboot
   macOS, and retry, or use `--firmware-dir`", `prepare-fedora-installer.sh:167`). The kit already
   prints the four validated filenames (`:544-547`); v2 adds the **board name, the model, and the
   sentence that decides whether the user wipes macOS next week**: these files are specific to this
   Mac and cannot be downloaded later. A plural capture (two `.trx` sets after a board swap) stops
   being a `die` and becomes a menu.
5. **Write, verify, carry, and the last thing they read.** The ISO is written, re-validated, the ESP
   edited with free-space pre-checking and `cmp` on every file. The closing block is rewritten: it no
   longer promises a terminal-based phase-2 installer that v2 deletes, and it no longer says "Fedora"
   where the screen will say `bluefin-t2`. It names what will happen: Option-boot, the keyboard will
   work, the installer will ask to enrol a key, and first login will say what works.
6. **Booting the USB, and the installer.** The win is stated in the product's own words at the moment
   it lands: the internal keyboard and trackpad work in the installer, which is the thing no other
   atomic T2 image does. Two silences are filled: the Touch Bar is inert during the install because
   no bar daemon runs in the live environment (said in `INSTALL.md` and on the enrolment screen's
   preceding page), and the firmware payload is being copied into the installed system by the
   post-script (§6 R2-3), so "Wi-Fi works after install" is not an open question at the user's end.
7. **The enrolment screen.** One screen, designed as copy before it is designed as mechanism: what
   the key is for, that Secure Boot stays on, that the code is confirmed at the next boot, and — the
   sentence that matters — what happens if you walk away, printed on the screen with the recovery
   (re-run the kit, or boot the live medium with an external keyboard). On route 2 the same content
   becomes a documented `mokutil --import` step *before* the switch.
8. **First boot.** Plymouth, GDM branding, GDM, and one per-user unit that runs once. If it fails,
   the failure is no longer silent: `bluefin-t2 report` reports the binding state, and the Touch Bar
   failure line (§below) covers the bar.
9. **First login and the firmware import.** The import unit runs before networking and runs
   unbind → remove → install → rebind, then restarts NetworkManager. What changes is that the user is
   told: the first-login surface (§below) reports the import as an event, not as Wi-Fi happening to
   appear. If the payload did not cross, the surface names the four files, the exact path and the
   command.
10. **The first week.** `bootc upgrade`, the first suspend in a bag, the first missing fingerprint
    prompt. v1's criteria stop at boot; v2's surfaces do not. `bluefin-t2 report` stays reachable
    forever (`bluefin-t2` with no arguments), `UPGRADING.md` explains what a kernel bump does, and the
    bug-report template is the report's own `--markdown` output.

### The hub, and its Overview

One new app, `bluefin-t2`, is the single visible entry point. Every existing app stays as it is — not
rewritten, not merged, not re-branded — and the six inherited desktop entries are set
`NoDisplay=true`, launched unchanged from the hub's rows. One icon in the app grid, and it carries the
product's name.

```
+------------------------------------------------------------------+
| bluefin-t2                                     [ MacBookPro16,2 ] |
+---------------------+--------------------------------------------+
| Overview         ●  |  THIS MACHINE                              |
| Display (Touch Bar) |  validated model · Secure Boot on, key     |
| Input & trackpad    |  enrolled · image 44.20261013 · kernel     |
| Thermal & fans      |  7.2.5-200.fc44.x86_64                     |
| Power               |                                            |
| Battery & SMC       |  WORKING                          11 of 11 |
| Audio               |  keyboard, trackpad, suspend, Touch Bar,   |
| Diagnostics         |  Touch ID, audio (16_2), fans, battery,    |
| Recovery            |  display, ports, Wi-Fi, Bluetooth, RTC     |
|                     |                                            |
|                     |  NOT WORKING                        none   |
|                     |                                            |
|                     |  EXPECTED ON THIS MODEL                    |
|                     |  hid_t2magicmouse — loaded, unbound:       |
|                     |  no Magic Mouse paired. Not a fault.       |
|                     |  t2gmux — not loaded: no GPU mux on this   |
|                     |  model. Not a fault.                       |
|                     |                                            |
|                     |  [ Save report as Markdown ]               |
+------------------------------------------------------------------+
```

Nine sidebar rows. Overview is the only new page; eight are links, and where a row maps to an
inherited app it launches that app unchanged. Two get their own small page because nothing else
shows them: **Display (Touch Bar)** carries `kait2en-touchbar --status`, the layer and learned-timeout
facts from `touchbar.toml`, and the "Use Apple's Touch Bar row" switch; **Recovery** is the block of
exact commands from G7. The hub reads `report --json` only — never the human format — so the schema is
the contract and there is one implementation of every assertion.

Why not the alternatives: eight visible peers is zero work and leaves the product with no front door;
merging the six crates into one libadwaita app is the honest full version, costs a rewrite of six
crates whose widgets are not library-ised, and buys nothing the hub does not already give; a hub that
embeds the six windows as pages commits us to tracking six upstream apps' internals across rebases,
which is the worst maintenance shape available to a project on a rebase treadmill.

### `bluefin-t2 report`

One executable, `bluefin-t2`: no arguments opens the hub; `report [--markdown|--json]` and
`firmware --import|--status` are subcommands. The report is the same assertion set the bench runs,
pointed at the user's machine.

- **Exit codes:** `0` everything this model expects is present; `1` something is not working; `2`
  this model is not in the validated set. **Exit 2 takes precedence over 1** — a report about an
  unvalidated model must not read as a pass or a failure of the project. The first-login unit decides
  whether to open a window by running it, not by duplicating the logic.
- **No network, no telemetry, no upload, ever.** `--markdown` writes a file in the user's home and
  prints its path. The product asks the user to paste it; it never sends it.
- **One screen, no scrolling at 80×25.** Header 1, working 1 + N, not-working 1 + N, expected 1 + N,
  footer 1.
- **Truthful about what it cannot know.** Anything unmeasurable is reported `untested`, never
  `working`.

Working machine, validated model:

```
$ bluefin-t2 report
bluefin-t2 44.20261013 (stable) · kernel 7.2.5-200.fc44.x86_64
MacBookPro16,2 · validated model · Secure Boot on, enrolment key present

WORKING    11 of 11
  keyboard, trackpad      initramfs and session, input path intact
  suspend / resume        last cycle 4.1 s, 0 failures this boot
  Touch Bar              daemon attached, layer "media", timeout 5 s
  Touch ID               fprintd active, 1 fingerprint, offered at login
  audio                  16_2 DSP sink present, UCM profile loaded
  fans                   curve active, 2 fans, 2150 / 2150 rpm
  battery, power         gauging daemon active, charge limit 100%
  display, ports         2 displays, 2 Thunderbolt ports
  Wi-Fi                  brcmfmac bound, firmware from /var/lib/firmware/brcm
  Bluetooth              hci0 up (UART controller, no Apple firmware needed)
  RTC, SMC, camera, mic  ok

NOT WORKING    none

EXPECTED ON THIS MODEL
  hid_t2magicmouse       loaded, unbound: no Magic Mouse paired
  t2gmux                 not loaded: no GPU mux on MacBookPro16,2

Report saved: no (nothing to report)
$ echo $?
0
```

Missing firmware — the state the first-login surface exists for:

```
$ bluefin-t2 report
bluefin-t2 44.20261013 (stable) · kernel 7.2.5-200.fc44.x86_64
MacBookPro16,2 · validated model · Secure Boot off

WORKING    9 of 11
  keyboard, trackpad      initramfs and session, input path intact
  Touch Bar              daemon attached, layer "media"
  Touch ID               fprintd active, 1 fingerprint, offered at login
  audio                  16_2 DSP sink present, UCM profile loaded
  fans                   curve active, 2 fans
  battery, power         gauging daemon active
  display, ports         2 displays, 2 Thunderbolt ports
  Bluetooth              hci0 up (UART controller)
  RTC, SMC, camera, mic  ok

NOT WORKING    1
  Wi-Fi                  no firmware. brcmfmac asked for 4 files and did not get them.
      These files are specific to THIS Mac and cannot be downloaded.
      Copy from the macOS you installed from: /usr/share/firmware/wifi/
      To here, on the ESP:                  /boot/efi/kait2en/firmware/wifi/
      Then run:                             sudo bluefin-t2 firmware --import
      No macOS any more? See /usr/share/bluefin-t2/RECOVERY.md

UNTESTED
  suspend / resume        no cycle recorded this boot     <- honest, not "ok"

EXPECTED ON THIS MODEL
  hid_t2magicmouse       loaded, unbound: no Magic Mouse paired
  t2gmux                 not loaded: no GPU mux on MacBookPro16,2

Report saved: none
$ echo $?
1
```

Model in the class but not validated:

```
$ bluefin-t2 report
bluefin-t2 44.20261013 (stable) · kernel 7.2.5-200.fc44.x86_64
MacBookPro15,4 · supported by the written argument, NOT validated on hardware
Secure Boot on, enrolment key present

UNTESTED ON THIS MODEL — this is a report, not a pass or a failure
  The 13-inch 2018-2020 Touch Bar models share the module set, the bar and
  the audio profiles with the validated MacBookPro16,2. Nothing below has
  been verified by this project on this model.

WORKING (by this machine's own checks)   9 of 11
  keyboard, trackpad, Touch Bar, Touch ID, audio, fans, battery, display,
  ports, Wi-Fi, RTC/SMC/camera
NOT WORKING    none observed
UNTESTED       suspend / resume, Bluetooth

EXPECTED ON THIS MODEL (from models.d/MacBookPro15,4.toml)
  t2gmux                 not loaded: no GPU mux on this model

This model is not validated. If you file an issue, attach:
  bluefin-t2 report --markdown > bluefin-t2-MacBookPro15_4.md
  /usr/share/bluefin-t2/MODELS.md says what is claimed and why.
$ echo $?
2
```

This output differs from `02-design.md`'s sample in one place, deliberately: 15,4's Bluetooth is
*covered* by the kernel board table (§1), and 16,2 has no BCM4377 at all, so Bluetooth is not
reported as broken on either. The alternative would have shipped a known-false line.

`--markdown` is the same content with a heading per section and one fenced block containing the four
firmware filenames and paths, and it is the body template of the bug-report issue form.

**Where it appears — three touchpoints, one artifact.** (1) First login, only on exit 1 or 2, once,
marker written, closes on keypress; nothing opens on a working validated machine, and that empty
state is the "it worked" signal. (2) The hub's Overview, always reachable from the app grid. (3)
`--markdown`, which writes a file and never uploads.

**What it is not.** Not a dashboard, not telemetry, not a health score. A user needs the one line that
says what is broken and the one command that fixes it. If a line does not change what the user does
next, it goes.

### `MODELS.md`, shipped in the image

`/usr/share/bluefin-t2/MODELS.md` is the supported-model page in the image — the same content as
`docs/WILL-IT-WORK.md`, which is the top docs priority (§10). It names the four class-A models and
their evidence tier, the class-B/Air/iMac deferrals with the reason each is deferred, the four-part
argument, the per-model expected-absent set, and the exact command that proves it on the reader's
machine (`bluefin-t2 report`, exit codes explained). It is written as a table plus a rubric plus a
proof command, because that is the form that also serves the contributor adding a model. It ships in
the image rather than only on the web because the machine with no Wi-Fi cannot read the web page — and
that is the machine whose user most needs it.

### The first-login surface, and when it does and does not open

**(Added 2026-10-22, hardware-driven.)** There is a second first-login surface: a dialog from
`/usr/libexec/bluefin-t2/first-run`, autostarted 20 s after login. It reports the setup state
(`fprintd` device, bridge, group, firmware, DSP graph) and, when the first session predates the
NCM link, asks for the one reboot KaiT2EN's first boot also asks for. It runs once per user
(`~/.local/state/bluefin-t2/first-run.done`); `--check` is the headless form, gated in the
image. The reboot is product behaviour now, not an operator's note.


One user unit (`bluefin-t2-first-login.service`, R2-9), one marker, one visible behaviour: on the
first login of a user without the marker, it runs `bluefin-t2 report`; if the exit code is `1` or `2`
it opens a terminal window with the report and closes on a keypress; if it is `0` it opens nothing and
writes the marker.

- **On a working validated machine, nothing opens.** That is the correct empty state and it is the
  trust signal, not an omission.
- **It cannot reach a session it does not own:** it is a user unit with `ConditionUser=!@system`, so
  the greeter never runs it, and it never fires from a system unit ordered before any session exists
  (which is why v1's desktop-notification plan reached nobody).
- **It never blocks the session:** it is `Type=oneshot` in the user manager, and the terminal window is
  the only thing the user sees.
- **It is not a one-shot product surface:** the same content is the hub's Overview and
  `bluefin-t2` with no arguments, so the "what works" answer is reachable on day 400, not just day 1.

### Trust and honesty surfaces

- **Secure Boot, one voice.** The word "No Security" does not appear anywhere in the product. Route 1:
  "Secure Boot stays on; the installer enrols a key; you will be asked to confirm a code at the next
  boot." Route 2: "run `mokutil --import` now, while your keyboard is attached, then confirm at the
  next boot, then switch." Both blocks replace the kit's inherited check
  (`prepare-fedora-installer.sh:87-102`), which v1 kept verbatim and which contradicted the design.
- **No Wi-Fi.** Not a missing icon. The import unit records its outcome, `report` names the four
  files, the two paths and the command, and the first-login surface prints exactly that with "these
  files are specific to this Mac and cannot be downloaded" above it.
- **Unsupported model.** A three-way verdict read from DMI `product_name`: **validated**,
  **supported by argument**, **unknown**. Each with the sentence that tells the user what to do next;
  the third says "not validated on this model, here is the report to attach to an issue". No hard
  refusal — the model that would work is not turned away.
- **No silent success.** Every daemon that used to succeed or fail invisibly now has a line in the
  report: fans, gauging, zone power, force click, power tune, Touch ID, t2-remote, the Touch Bar
  daemon. `systemctl --failed` is one of the report's rows, not a thing the user has to know to run.

### The Touch Bar: discoverability, and the escape hatch

The inherited craft is kept in full — dark-first, the learned 5 s→30 s timeout, three fixed layers
plus up to four personal keys, swipes on the dark bar, haptics through `t2_trackpad_actuator`, the
fingerprint prompt drawn on the bar, software-dimmed glyphs following the keyboard backlight, no Apple
artwork. Three additions, none of which touch the craft:

1. **A first-run lesson drawn on the bar.** On first login only, three panels light for ~4 s each,
   labelled in the product's own voice: "Swipe here for volume" over the dark bar, "Hold Fn for
   function keys" over the F-key row, "Tap for media" over the media row. Dismissible on the first
   touch, never shown twice, resettable through the existing `--reset-learning`. The last panel
   offers the one decision that matters on a laptop — *keep it dark, or keep it lit* — stored in the
   user's config so the learned timeout survives either way. That is design T3 resolved: dark-first
   stays the default, and the user who wants it lit gets it in one tap instead of a README.
2. **A visible failure line.** If the daemon starts but cannot attach — group missing, device absent,
   unit disabled — it says so **on the bar** for the first 30 s of the session, in one line, with the
   fix. Today's failure mode is a working-looking Apple row, indistinguishable from a design choice.
3. **A switch, in the hub's Display page, that does exactly what the upstream escape hatch does**:
   `systemctl --global disable kait2en-touchbar.service` and reboot, returning Apple's row. It is a
   legitimate preference, not a workaround, and offering it removes the fear of trying the bar.

Accessibility, specified and riding the first-run lesson rather than a new task: an "always lit,
F-keys" config mode so a keyboard-only session reaches `esc` and the function keys, and a minimum
contrast floor for the dimmed glyph colour against black. Haptics stay the only non-visual feedback;
that limitation is stated in `MODELS.md`, not hidden.

---

## 8. Naming

**One rule.** Surfaces *we author* take the `bluefin-t2` prefix — binaries, units, helpers, polkit
domains, data directories. Inherited KAIT2EN binaries, units, package names and config paths keep
their names, because that is factual reference under `TRADEMARK.md` (`:86-88`) and renaming them would
fork every rebase of a pinned submodule.

| New, therefore `bluefin-t2-*` | Inherited, therefore unchanged |
|---|---|
| `bluefin-t2` (hub + CLI), `bluefin-t2 report`, `bluefin-t2 firmware` | `kait2en-touchbar`, `t2journal`, `t2remote`, the eight app binaries |
| `bluefin-t2-first-login.service`, `bluefin-t2-provision-user` (helper), `org.bluefin_t2.provision-user` (polkit) | `kait2en-suspend`, `kait2en-rtc-sync`, `kait2en-t2-remote`, `kait2en-t2-touchid`, `kait2en-touchbar(-attach)`, `t2-fancontrol`, `t2-smc-gaugingd`, `t2-zonepowerd`, `t2-force-click`, `t2-services-suspend` |
| `bluefin-t2-firmware-import.{service,path}`, `bluefin-t2-nm-bridge.service` | `/etc/kait2en/*`, `/usr/share/alsa/ucm2/AppleT2/*`, `/usr/share/t2-dsp/*`, `kait2en-touchbar` group |
| `bluefin-t2-hil-{early,userspace,test}.service` (harness only), `bluefin-t2:hil` images | `/etc/pki/akmods/certs/` (ublue convention) |
| `/usr/share/bluefin-t2/` (`MODELS.md`, `RECOVERY.md`, `models.d/`), `/var/lib/bluefin-t2/` | the 12 kmod RPM names, which match KAIT2EN's `dkms.conf` package names so review stays per-module |

**Fifteen units ship, and that number is checkable.** Eleven are inherited — ten system
(`kait2en-suspend`, `kait2en-rtc-sync`, `kait2en-t2-remote`, `kait2en-t2-touchid`, `t2-fancontrol`,
`t2-smc-gaugingd`, `t2-zonepowerd`, `t2-force-click`, `t2-services-suspend`,
`kait2en-touchbar-attach`) and one user (`kait2en-touchbar`, enabled globally); all eleven are
preset-enabled. Four are ours: `bluefin-t2-first-login.service` (user, preset),
`bluefin-t2-firmware-import.service` and `bluefin-t2-firmware-import.path` (system, preset,
conditioned on the incoming `SHA256SUMS`), `bluefin-t2-nm-bridge.service` (system, preset, first
boot). The three harness-only units (`bluefin-t2-hil-{early,userspace,test}.service`) ship in the
harness image, never in the release image.

**(Corrected 2026-10-22.)** The per-user `bluefin-t2-first-login.service` is gone; see the R2-9
correction above. The four ours are now `bluefin-t2-user-groups.service` + `.path`,
`bluefin-t2-firmware-import.service` + `.path`, and `bluefin-t2-nm-bridge.service`. The
nm-bridge must create **or reconcile** a profile with `autoconnect=true`,
`autoconnect-retries=0`, `ipv4.method disabled` and `ipv6.method link-local`. Its first
version used `autoconnect=no`, so the T2 CDC-NCM link never came up, IPv6 never appeared, and
both `t2remote` and the Touch ID bridge waited forever (Tier 2, 2026-10-22).

Two consequences worth stating: the v1 names `kait2en-firmware-status` and `kait2en-import-firmware`
disappear because they were ours, not inherited — `bluefin-t2 report` and `bluefin-t2 firmware
--import` replace them — and `kait2en-touchid-bind.service` disappears into
`bluefin-t2-first-login.service` because it was a duplicate mechanism for one event.

---

## 9. Test strategy

Four tiers, one harness image, named-set assertions throughout. No tier asserts a bare count.

### Tier 0 — container conformance, no T2 hardware, no reboot

**The harness is the republished akmods build container, not a new image.** `akmods-t2:harness` is
built by A1, already carries `kernel-devel` at the target kver because it compiles the modules, is
cosign-signed, and can never drift from the kernel it tests. It runs in CI on every commit and
locally through one documented `podman run`. Assertions run in the harness against the built image's
filesystem mounted read-only — not inside the image, which has had `/usr/src` and `kernel-devel`
removed by Bluefin's `05-override-install.sh` and therefore cannot run `extract-module-sig.pl`.

- Every object in the **named 18-object set** is present for the target kernel; `modinfo -F vermagic`
  equals `<kver>`; `depmod -a` reports no unknown symbols; `modprobe --dry-run` proves dependency
  order and existence only. Symbol *resolution* is proven by `depmod`'s clean run plus the load in
  Tier 2 — there is no VM tier.
- `rpm -qpR` on all 12 kmod RPMs contains `kernel-core-uname-r = <KVER>`.
- Signature verifies per module via `extract-module-sig.pl` + `openssl cms -verify -certfile`.
- Initramfs built for the target kernel, then `lsinitrd` asserts **both** named lists: the six
  installed-image objects and the five installer objects.
- `systemd-analyze verify` on all 15 shipped units plus the three harness-only units (the four we
  author are verified from T7 on; the eleven inherited units are verified once their packages are
  installed — T4 step 03), and `systemctl --root=<image> preset-all --dry-run` followed by asserting
  the generated `*.wants` symlinks exist.
- The SELinux module is present at priority 400 and `semanage module -l` lists it.
- `/etc/pam.d/system-auth` contains `pam_fprintd.so` (corrected 2026-10-21: authselect's
  `with-fingerprint` feature writes the auth stack only — `password-auth` is the
  password-change stack and takes no fingerprint, so asserting it there was wrong); the build-only set
  (`gcc make checkpolicy policycoreutils rpm-build cargo rust` and the `-devel` packages) is absent
  **and** no build residue exists anywhere in the filesystem — the second half is the assertion an
  RPM query could not make.
- `udevadm verify`, `pkaction --verbose`, `desktop-file-validate` on all seven entries,
  `appstreamcli validate`, PipeWire/WirePlumber config parse, `alsaucm` profile load.
- `/usr/lib/bootc/kargs.d/00-t2.toml` parsed and compared to the **13-name expected list**, diffs
  fail.
- `models.d/*.toml` parse against one schema; each supported model's expected set names all 18
  objects exactly once across its three categories.
- Negative tests: (a) step 01 with a `KVER` that has no `akmods-t2` tag → nonzero exit and the exact
  named error; (b) a wrong-kver RPM forced into the unpack directory → install fails; (c) delete a
  `force_drivers` entry → the build fails at `lsinitrd`; (d) point `report` at fixture DMI strings →
  exit 0, 1 and 2.
- Cross-model static assertions, no hardware: every shipped unit no-ops without its device, the DSP
  map covers all four class-A models, and the kargs list contains no per-model branch.
- Compressed image delta against plain Bluefin stays under 250 MB; the build fails if it does not.
- `bootc container lint`. Policy assertions phrased negatively: **no runtime unit, script or
  image-owned hook invokes `grubby`, `dkms` or `semodule`; no `/boot` writes; nothing under
  `/etc/kernel/install.d`** — the build does run `semodule -i` by design, so the module's presence is
  a separate positive assertion.

### Tier 1 — live host, real hardware, no reboot

The host is a T2 Mac; CI cannot offer that. Compile against `$(uname -r)` and load **only the safe
set**: `t2smc`, `t2thunderbolt`, `t2mfi_fastcharge`, `t2smp`. **Never** `t2hid`, `t2bce_*` or
`hid_t2magicmouse` — unloading those locks the keyboard on the machine doing the test, and the
listing is in `CONTRIBUTING.md` and `AGENTS.md`, not only in this document. Preconditions: a second
boot target or an external keyboard attached, and the rollback command stated per step
(`modprobe <dkms-built module>` from `/usr/lib/modules/$(uname -r)/updates/dkms/`). A single module
may be built on the Mac itself for this tier (DX TD4); the page says the vermagic will not match the
image. This is also where the packaged userspace is validated against live hardware: hwmon sensors,
audio profile selection, `fprintd-list`.

### Tier 2 — hardware-in-the-loop, per-release gating

**Cadence: per release (closed call 1).** The guarantee is "no release ships without a recorded
Tier 2 run", not "every daily build is tested". The harness records per-stage wall clock onto the
results stick, so the cost is a measurement rather than an argument — v1's 15–20 minutes and the eng
review's 35–55 minute estimate are both replaced by a number this project publishes.

- **Install invocation, pinned and recorded:** `sudo podman run --privileged --pid=host --rm -it
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers quay.io/fedora/fedora-bootc:44 bootc
  install to-disk --source-imgref ghcr.io/<org>/bluefin-t2@sha256:<digest> /dev/nvme1n1`. `bootc` is
  absent from the host, so it comes from the container; the tested digest goes into `result.json`.
- **Results live on a separate device.** `bootc install to-disk` claims and repartitions its target,
  and the internal root is LUKS-encrypted, so results cannot share the installed disk. They go to a
  dedicated FAT32 stick (`K2B-HIL`), mounted at `/run/media/<user>/K2B-HIL` on the host and at
  `/var/mnt/hil` on the test system by a harness unit. A single-disk setup is possible only via
  partition-by-hand plus `bootc install to-filesystem`, and it is stated as an option, not the default.
- **The attempt marker is written before boot, by the host** (R2-11), with the four-branch outcome
  table. The photograph is a required field for the `FAILED_BOOT` branch, not an operator habit. The
  harness is the only thing that can observe a pre-Linux failure, which is why it runs outside the
  machine.
- The payload is pre-placed on the external disk's ESP *after* the install and *before* first boot, so
  the import path is exercised for real.
- The smoke test asserts the **named 18-module set** with the model's three categories from
  `models.d`, plus: no `firmware load failed` in `dmesg`, Wi-Fi associated, Touch Bar usable **as the
  desktop user**, `fprintd-list` non-empty, the fingerprint offered at the lock screen,
  `systemctl --failed` empty, **one suspend/resume cycle**, `wpctl status` shows the DSP sink. Then it
  powers off.
- **Recovery contract:** never install to the internal disk; Option-boot back; previous deployment
  pinned.
- The other two validated models (15,2, 15,4) get their first recorded run when the bench has them,
  and their `models.d` files change from `unmeasured` to measured by that run, not by prose.

### Tier 3 — kit and ISO, gated

One HIL run per ISO build using the real kit and a real USB stick: the ESP initramfs injection, the
GRUB rewrite, the firmware capture and carry, and a clean install with **no external hardware
attached**. Then, after the install and before first boot, mount the target ESP and assert the four
firmware files, `SHA256SUMS` and `firmware-import.json`; boot and assert Wi-Fi associates. Negative
runs: a wrong-board payload (must be refused), the target ESP filled (install must fail with the named
message), and the USB pulled mid-install (must fail at the payload copy, not after a reboot). Secure
Boot states (b) and the deliberately-skipped (c) are produced here with the boot-menu rollback
executed and recorded. Route 2 is a scripted procedure on a stock Bluefin T2 machine once per release
cycle. Without this tier the headline success criterion rests on untested code.

### The rotation drill

Once per key rotation, not per release (T15): install with key A, upgrade to an image signed with A
and B, remove B from the MOK list, upgrade to B only, confirm the documented rollback. No tier catches
rotation otherwise, and a lockout is forever.

---

## 10. Distribution and docs

### Publication

| Artifact | Where | Signed | Notes |
|---|---|---|---|
| `ghcr.io/<org>/akmods-t2` | tags `<flavor>-<fedora>-<KVER>`, floating `<flavor>-<fedora>`, `harness` | cosign, our key | both real tags carry `ostree.linux`; `rpm -qpR` is the lock |
| `ghcr.io/<org>/bluefin-t2` | `stable`, `latest`, plus the digest | cosign, our key | also the ISO's source image |
| ISO | GitHub release asset + checksums | cosign + SHA-256 | built by BIB from the image digest |
| Kit | GitHub release asset, **versioned**, with `--version` (which prints the image release it supports), `--check` (verifies, captures, renders, size-checks, writes nothing) and a `SHA-256` | cosign + SHA-256 | no download piped into a shell. The documented command downloads, verifies with `shasum -c`, prints the target disk and requires a typed confirmation |
| Corresponding source | `source-<version>` tag + tarball | — | KAIT2EN submodule at the pinned commit plus our patches; GPL-3.0-or-later userspace, GPL-2.0 modules, kit under GPL-3.0-or-later with a `NOTICE` naming the fork point |

`bootc switch --enforce-container-sigpolicy` reads `/etc/containers/policy.json`, which arrives from
`projectbluefin/common` and pins ublue's keys. The build appends our registry and cosign key to that
file; without it the verification claim is false for users. Rebuild cadence: daily cron against
Bluefin Classic, `repository_dispatch` on KAIT2EN movement, manual — **with the release gate per
release**, so a daily build that fails Tier 2 is a build nobody is offered, not a release.

### The nine docs pages, in priority order

Priority is "how much pain its absence causes". Written after Tier 3 where they describe a screen it
exercised.

| P | Page | Audience | In the image? |
|---|---|---|---|
| 1 | **`WILL-IT-WORK.md`** — "is my Mac the one", the four-part argument, the per-model table and expected-absent set, the proof command | user + contributor | **Yes**, as `/usr/share/bluefin-t2/MODELS.md` |
| 2 | `INSTALL.md` — route 1, numbered, prerequisite box at the top, `shasum` check, the `ERASE` phrase shown before it is asked for, the four filenames, what the next boot looks like | user | No |
| 3 | `RECOVERY.md` — Option-boot, previous deployment, firmware from a stick, "no internal keyboard" triage, and the decision on which of `kait2en-live-wifi`, `-bluetooth`, `-diagnostics`, `kait2en-rescue` survive | user | **Yes**, same directory |
| 4 | `FIRMWARE.md` — what the four files are, why they are per-machine, the licence position, where they go, the `--firmware-dir` layout | user | No |
| 5 | `CONTRIBUTING.md` — the on-ramp below, plus what a contributor without a T2 Mac cannot verify and how to say so | contributor | No |
| 6 | `ADD-A-MODULE.md` — the template, the `just module` loop, the four traps, the twelve-module dependency order, the per-PR checklist | contributor | No |
| 7 | `UPGRADING.md` — what `bootc upgrade` does to the setup, what CI guarantees, how to roll back, the first kernel bump | user | **Yes** |
| 8 | `KIT-REFERENCE.md` — every flag, error string, exit code, and the `--check` behaviour | user + contributor | No |
| 9 | `ARCHITECTURE.md` — four artifacts, the kernel lockstep, why the derivative regenerates its initramfs, where the payload crosses | contributor | No |

Sequencing: pages **1, 4, 5, 6, 9** before Tier 3, because they describe behaviour that already
exists by then (the class argument, the firmware mechanism, the build loop, the architecture); pages
**2, 3, 7, 8** immediately after the first green Tier 3 run, describing only what it exercised. This
follows the reviews' rule — a page describing a screen that does not work is a lie shipped to users —
and adds 5 and 6 to the pre-Tier-3 set because the spec loop they document is exercised by T1–T2, not
by the ISO. Two rules for all nine: every command block has been pasted from a real run, and every
page is versioned against a release.

### The contributor on-ramp, in order

Steps 1–4 are a day. Steps 5–8 are the difference between "someone could" and "someone did".

1. **A repository with an identity:** public, `README.md`, `LICENSE` (GPL-3.0-or-later), the shipping
   name, one paragraph of what it is, a link to this document.
2. **`CONTRIBUTING.md`** with the first-day path and the hardware honesty section: Linux x86_64 with
   podman (not a Mac, for the image), the devcontainer one-liner that already works, the eight steps
   to a signed module, and the plain statement of which verification steps need a T2 Mac.
3. **One template spec plus one per-module build target** — `just module t2smc 7.2.5-200.fc44` that
   builds, signs and verifies a single `.ko`. **The mechanism split is closed call 3:** the
   `rpmbuild` template (KAIT2EN's `kmod-kait2en-input.spec` + `build-input-kmod.sh` pattern) is the
   contributor loop, because it builds one RPM for one kernel in about a minute and it has been used
   in anger; `akmods --force --kernels <kver>` is the published artifact, because it is the mechanism
   that gives `akmods-t2` its daily kernel chase and its tag. `ADD-A-MODULE.md` says both and which to
   run when.
4. **`ADD-A-MODULE.md` with the four traps:** where a spec lives (there is no kmod spec directory in
   the fork base — one is created), the twelve-module dependency order
   (`t2bce_dma → t2bce_core → t2bce_vhci` is real), the `KERNEL_SRC`/`KERNEL_RELEASE` divergence
   (`modules/t2smc/dkms.conf:4` against the other eleven's `KDIR`/`KVER`, e.g.
   `modules/t2touchbar/dkms.conf:4`), the three-kernel rule (host, image, ISO), and where a per-module
   compat patch goes.
5. **The harness image, or a documented `podman run` that reproduces Tier 0 locally** — `akmods-t2:harness`
   is already published by A1; without a local reproduction path a contributor cannot run the gate
   they are asked to pass.
6. **CI on PR: Tier 0 plus the fail-closed tag check.** The tag check is also a contributor-facing
   message — it is what stops a PR merging into an image that cannot build.
7. **Issue templates:** bug (`report --markdown`), model report, add-a-model request, module proposal.
   The first is free because the report already writes the body.
8. **A bench note:** what a contributor without hardware can and cannot prove, and the one-line
   warning that unloading `t2hid`, `t2bce_*` or `hid_t2magicmouse` locks the machine out. That warning
   currently lives in this project's contract and not in any repo a contributor will fork, which means
   the person most likely to need it will never read it.

---

## 11. Edge cases and untested edges

### Edge cases

| # | Scenario | v1 | v2 must do | Tested by |
|---|---|---|---|---|
| 1 | Kernel bump mid-flight | undefined; only fail-safe is a compile failure in A1 | resolve `KVER` once from the pinned digest's label, then find the tag or stop; no partial image is pushed | Tier 0 negative (no tag) |
| 2 | Base digest updated, `akmods-t2` stale | build proceeds with whatever `skopeo copy` resolves | `skopeo inspect` + cosign verify on the exact kver tag; nonzero exit with a named error | Tier 0 negative + `rpm -qpR` |
| 3 | A 15,4 or 15,2 (class A, unvalidated) | installs, behaves differently, nothing says so | exit 2, three-way verdict, expected lines from `models.d` | Tier 0 fixture; Tier 2 on that model |
| 4 | Payload from the wrong board | kit dies on board mismatch at capture; nothing for the *target* | kit prints captured chip/board and the expected board; the post-script records the board in `firmware-import.json`; `report` compares them and says "captured on a different Mac" | Tier 3 with a deliberately wrong payload |
| 5 | Secure Boot toggled after install | not addressed | `report` asserts `mokutil --sb-state` and enrolled keys; enabling SB without our key is reported before it bites; recovery is the GRUB rollback | Tier 2 spot check; Tier 3 state (c) |
| 6 | Target ESP full | kit checks only the **USB** ESP (`prepare-fedora-installer.sh:655-663`) | same check for the target ESP in the post-script, byte count from the payload; failure fails the install | Tier 3 negative (fill it) |
| 7 | macOS partition absent | kit dies "must run on macOS" (`:430`); route 2 is prose | route 2 page with the MOK step, the firmware-on-a-stick step and each boot stage; the die names route 2 | docs review; one scripted route 2 run per cycle |
| 8 | Two T2 Macs, one USB | the stick would carry one machine's firmware and both would import it | payload keyed by board name; the second machine's import refuses with "captured on a different Mac" and the recovery is re-running the kit there | Tier 3 negative (wrong-board case) |
| 9 | USB removed before the install finishes | undefined | the install fails at the payload copy with a named error (`--erroronfail`), not after a reboot | Tier 3 negative |
| 10 | A second user logs in | the bind unit is per-`%h`, so both users would fight over one config value | the second user's helper finds `T2_TOUCHID_BIND_USER` set, logs one line, and does not restart the daemon | Tier 0 unit test with two fake HOMEs |
| 11 | Key rotation, user never enrols the new key | not addressed | dual-sign overlap for two releases; `report` says "MOK: old key only, run `mokutil --import`"; after the overlap, the upgrade is documented as requiring enrolment | rotation drill |
| 12 | NVRAM/PRAM reset clears MOK | not addressed | `report` detects "SB on, no key enrolled" and prints the command; `RECOVERY.md` names the GRUB rollback | Tier 2 after a deliberate NVRAM reset |
| 13 | `brcmfmac` import on an already-bound PCI function | v1's unbind → remove → install → rebind is correct | unchanged, plus a failure branch: if unbind returns nonzero, log the bus id, do not remove the module, restart NM anyway, leave Wi-Fi absent with a state file rather than hanging | Tier 2 |
| 14 | No Wi-Fi in macOS during the kit run | dies with cause, fix, escape hatch — the best message in the product | unchanged, plus the `--firmware-dir` layout documented | Tier 3 variant |
| 15 | Suspend/resume after a kernel bump | no assertion ties suspend to the new `KVER` | Tier 2 asserts one suspend cycle per release; a failure is a release stop, not a note | Tier 2 |

### Untested edges

Each named with where it belongs; none of them is silently assumed.

1. **The `updates.img` post-script actually runs.** Only Tier 3 can prove it, and Tier 3 is the last
   gate before release. If it fails, the fix is a kickstart block and a new ISO — a full rebuild.
2. **A machine-local kernel arg surviving `bootc upgrade`.** Needs a throwaway install and two
   upgrades; belongs to the v2 per-model kargs probe. Nothing in v1 depends on it and nothing tests
   it, so it will be discovered late.
3. **Key rotation end to end.** No tier rotates a key; the drill is defined (T15) and is not in any
   tier's cadence.
4. **A second model.** Tier 2 runs the bench it has. The class's other validations are recorded runs
   when they happen; 16,3 is proven by argument only. That is a stated decision, not an oversight.
5. **The kit on a machine with more than one internal disk, or a Fusion/APFS container.** The kit
   lists external disks only and refuses internal ones, but nothing tests an external enclosure
   macOS reports as `Internal`.
6. **`bootc switch` from a stock Bluefin that already has user-added deployments or container
   customizations.** Route 2's interaction with them is unexamined.
7. **The report's `--json` schema across versions.** The hub and `result.json` depend on it; nothing
   tests that an older hub reads a newer report, which matters because the image updates underneath
   a user.
8. **Suspend with the HIL stick attached.** The Tier 2 suspend cycle runs with the results stick
   mounted; a user's suspend does not. It is the only suspend evidence the project will have.

---

## 12. Open questions

Four, and nothing else. The reviews left two more to the human — where the firmware-crossing code
lives, and the key-rotation policy — and both are decided (closed calls 4 and 2), which is why this
list is short.

1. **Do the 18 objects compile unmodified against Bluefin's current kernel?** Nothing has proved it.
   They satisfy KAIT2EN's ≥7.0 floor, but the per-release patch practice exists for a reason: the
   input stack carries `patches/fedora-44-input.patch`, and a compile failure on a kernel bump is a
   scheduled risk, not a surprise. T1 answers this in an afternoon. **Partly answered, 2026-10-20:**
   `t2smc` compiles unmodified, signs and binds on the host's real T2 kernel (`7.2.11-200.fc44`), and
   compiles and signs against the pinned image kernel (`7.2.5-200.fc44`). That is one of the 18; the
   other 17 remain unproven, and T2 is the test. Record: `research/findings/module-pipeline.md`.
2. **Does the Anaconda version in the BIB ISO execute `updates.img` `post-scripts`?** Documented, not
   proven in this tree. Tier 3 is the test; the kickstart `%post` is the documented fallback, decided
   at the first ISO build.
3. **Multi-model hardware access.** 15,2 and 15,4 are decision 6's validation set, and each carries
   a published claim only once its own digest-pinned Tier 2 run is recorded. The release that first
   claims a model must record that run; a release that has not run it says so in its notes, and the
   honest table until then is "16,2 recorded; 15,2 and 15,4 next; 16,3 by argument". This is a
   scheduling question about a bench and two machines, not an engineering one, and it is the only
   open item hardware alone can close.
4. **KAIT2EN upstream drift.** Consumed as a pinned submodule with no coordination channel and no PR
   path (`REPOSITORY` rules; `TRADEMARK.md`). Divergence is managed by rebasing, and the end state —
   a `t2` flavour in `ublue-os/akmods` — is deferred coordination work rather than a v1 dependency.

5. **Can A1 rebuild for a `KVER` that has aged out of the Fedora repositories?** Added 2026-10-20 by
   the T1 proof. `kernel-devel-7.2.5-200.fc44` is no longer in `updates` (only `7.2.11` is); it was
   obtainable only from Fedora's koji, and those RPMs carry no GPG signature. A late rebuild therefore
   trades a signed-repository provenance chain for an archived, unsigned one. Consequences: A1 must
   build while the release is current; the immutable `<flavor>-<fedora>-<KVER>` tag is load-bearing,
   not cosmetic, because it is the only clean way to reuse a kmod once the source kernel has aged out;
   and a late rebuild, if ever needed, must hash-pin the kernel-devel payload rather than weaken a
   signature check. Evidence: `research/findings/module-pipeline.md`.

---

## 13. Success criteria

- **Device class:** the claim published with a release never exceeds that release's recorded runs.
  16,2 has one; 15,2 and 15,4 are the validation set and hold a published claim once theirs is
  recorded; 16,3 is supported by the written argument and says so. The four-model claim itself never
  shrinks — only the tier each model is published in. No claim outside class A.
- **Install, route 1:** on a class-A Mac that still boots macOS, the kit-prepped ISO installs with no
  external keyboard, mouse or ethernet. Route 2 is exempt, says so, and documents the keyboard it
  needs until the first post-switch boot.
- **Secure Boot, both designed states, asserted with the digest recorded:** (a) SB off → the named
  18-object set loads; (b) SB on with our DER enrolled → it loads, and the keyboard works in the
  initramfs at the LUKS prompt. State (c) — SB on, not enrolled — is produced deliberately on a
  throwaway install to prove the failure mode and the recovery: the previous deployment from the GRUB
  menu, or a re-run of the kit / live medium with an external keyboard where no previous deployment
  exists. The criterion passes only when (a) and (b) both hold.
- **The report exists and is correct:** `bluefin-t2 report` returns 0/1/2 on the fixtures Tier 0
  feeds it, its `--markdown` output is the bug-report template's body, the hub renders the same
  content from `--json`, and the first-login surface opens on 1 or 2 and on nothing else.
- **No external hardware, scoped to route 1** and conditioned on macOS still booting — the
  precondition is stated in the docs and in the kit's `--help`, and route 2 exists for machines
  without macOS.
- **Fleet-wide claims only where validated:** the class argument is published with its evidence tier
  per model; the machine says which tier it is on.
- **Release gate:** every release has a recorded Tier 2 run with its digest and its measured wall
  clock; the wall clock is published, not estimated.
- **Wi-Fi** associates on first boot after the payload is imported, with no step beyond running the
  kit, and the import's unbind/rebind is proven by Tier 2.
- **Suspend and resume work for ten consecutive cycles.** The baseline exists: 30 clean cycles in 30
  days on this machine.
- **Touch Bar** renders the KAIT2EN bar and is usable as the desktop user; **Touch ID** authenticates
  through fprintd and is offered at login; internal speakers use the model's DSP profile; fans follow
  the KAIT2EN curve.
- **`bootc upgrade`** to a new Bluefin kernel either works or fails Tier 0 in CI — never ships a
  mismatched vermagic. **Rollback** from the boot menu restores a working machine after any failed
  update, and `RECOVERY.md` is the page that says so.
- **Tier 0 green on every commit;** one Tier 3 run per ISO build; one rotation drill per rotation.
- **Size:** the compressed image delta against plain Bluefin stays under 250 MB.

---

## 14. Implementation tasks

Fifteen tasks, four lanes. Effort is human-first with the agent estimate beside it. **The first task
is T1**, and it is first because it produces the one line that makes everything downstream
enforceable.

- [ ] **T1 (P1, ~2 days / ~3h) — Artifact 1: one module, two kernels, one RPM dependency.** Build
      `t2smc` from the pinned submodule for the host kernel (`7.2.11-200.fc44`), sign it with the new
      key, `modprobe -r t2smc`, load it, confirm `sensors` shows the channels. Then build the same
      module for Bluefin's labelled kernel (`7.2.5-200.fc44`) and verify it without loading:
      `modinfo -F vermagic` matches, `depmod` clean, CMS signature verifies. **New, and why this is
      first:** assert `rpm -qpR kmod-t2smc-*.rpm` contains `kernel-core-uname-r = 7.2.5-200.fc44.x86_64`.
      Files: `akmods-t2/specs/kmod-t2.in`, `specs/kmod-t2smc.spec`, `Justfile`, `certs/`.
- [ ] **T2 (P1, ~1 day / ~3h) — the remaining 11 specs, in dependency order.**
      `t2bce_dma → t2bce_core → t2bce_vhci → t2bce_audio → t2bce_ave` (one spec, `t2bce_stack`), then
      `t2touchbar`, `hid_t2magicmouse`, `t2bdrm`, `t2smc`, `t2sbs`, `t2mfi_fastcharge`, `t2gmux`,
      `t2thunderbolt`, `t2smp`, `t2_precision_trackpad`, `t2_trackpad_actuator`. Handle the `t2smc`
      `KERNEL_SRC` divergence. Verify: 18 objects built, signed, verified; `rpm -qpR` on all 12.
- [ ] **T3 (P1, ~3h / ~45min) — publish and tag.** Publish `<flavor>-<fedora>-<KVER>`, the floating
      `<flavor>-<fedora>` and `harness`, all with `ostree.linux` and all cosign-signed; add the
      `KVER`-resolution step from ublue's floating tag.
- [ ] **T4 (P1, ~1 day / ~2h) — Artifact 2's Containerfile, both stages, steps 01–08.** One file, the
      order locked in §5. Verify: builds; `90-tests.sh` green; `bootc container lint` green.
- [ ] **T5 (P1, ~4h / ~1h) — the initramfs guarantee, inside the build.** Move the `lsinitrd`
      assertion into `90-tests.sh`; assert the six objects by name; `modinfo -F vermagic` for all 18;
      assert `modules.dep` contains `t2bce_vhci`. Verify: deliberately break one `force_drivers`
      entry and confirm the build fails.
- [ ] **T6 (P1, ~2h / ~30min) — kargs, as a named set of 13.** Write
      `usr/lib/bootc/kargs.d/00-t2.toml`; replace the count assertion with a diffable list; delete
      the count.
- [ ] **T7 (P1, ~4h / ~1h) — units: fix the conditions, one provisioning helper.**
      `ConditionPathExists=!%h/…`, `ConditionUser=!@system`, the polkit action with
      `allow_active=yes`, the helper that takes no argument, the `SHA256SUMS` condition on the import
      unit, the `.path` unit's watched path separated from the service's output.
- [ ] **T8 (P1, ~1 day / ~2h) — the firmware crossing.** The post-script in the updates image,
      `SHA256SUMS` verification, target-ESP space check, `firmware-import.json`, `--erroronfail`.
      Verify: Tier 3 with a good payload and with a wrong-board payload.
- [ ] **T9 (P1, ~3h / ~45min) — route 2, end to end.** The documented procedure, the MOK step before
      the switch, the DER release asset, the `report` MOK check. Verify: one scripted run on a stock
      Bluefin T2 machine.
- [ ] **T10 (P1, ~1 day / ~2h) — `bluefin-t2 report` and `models.d/`.** One binary with three output
      modes and exit codes 0/1/2, no network, the `--json` schema written down as the contract,
      including the three per-model categories. Verify: fixtures for 0/1/2; schema test.
- [ ] **T11 (P2, ~1 day / ~3h) — the hub app.** Reads `--json` only; `NoDisplay=true` on the six
      inherited entries; the first-run Touch Bar lesson and the failure line; the "Use Apple's row"
      switch. Verify: `desktop-file-validate`, `appstreamcli`, fresh-install icon count.
- [ ] **T12 (P1, ~4h / ~1h) — the HIL harness and its three artifacts.** Host-side `attempt.json`
      writer, the two stage loggers, the host-side evaluator with **four** branches (the review's
      task text says three; its outcome table has four), the required photograph field. Verify: four
      synthetic runs, one per branch.
- [ ] **T13 (P2, ~2h / ~30min) — the BIB ISO and its config.** Disk type, the kickstart carry if the
      post-script route fails, the module enable/disable list modelled on
      `research/t2-atomic/disk_config/iso-bluefin.toml:7-18`.
- [ ] **T14 (P2, ~1 day / ~2h) — Tier 3's first green run, then pages 2, 3, 7 and 8.** Verify: a
      stranger reads page 1 and answers "will it work on mine" without a terminal.
- [ ] **T15 (P3, ~1 day / ~2h) — the rotation drill.** Install with key A, upgrade to an image signed
      with A and B, remove B from the MOK list, upgrade to B only, confirm the documented rollback.

| Lane | Steps | Depends on |
|---|---|---|
| L1 kmods | T1 → T2 → T3 | — |
| L2 image | T4 → T5, T6, T7 | T3 for a real tag; a stub works until then |
| L3 install | T8, T9, T12, T13 | T4 |
| L4 surfaces | T10 → T11, T14, T15 | T4 |

**Launch L1 alone. Start L2 as soon as T1 produces one signed RPM. L1 and L2 share no files; L3
depends on T4; L4 depends on T4.** The only cross-lane shared tree is `system_files/shared/` (L2 and
L4), so sequence T7 before T10.

---

## 15. The Assignment

Prove the module pipeline on its own, with no image involved, in **one afternoon**, and accept that it
needs two kernel builds.

**First:** build `t2smc` from the KAIT2EN sources for **your host's kernel**
(`uname -r` = `7.2.11-200.fc44.x86_64`), sign it with your new key, `modprobe -r t2smc`, load yours
with `modprobe t2smc`, and confirm it binds — `sensors` shows the fan and temperature channels,
`modinfo t2smc` reports your signature. That proves the sources and the signing path against a real
T2 kernel. It does not touch the keyboard modules, and the rollback is `modprobe t2smc` from
`/usr/lib/modules/$(uname -r)/updates/dkms/`.

**Second:** build the same module for **Bluefin's kernel** (`7.2.5-200.fc44.x86_64`, read from the
image's `ostree.linux` label) and verify it *without loading it* — `modinfo -F vermagic` matches,
`depmod` reports no unknown symbols, the CMS signature verifies against your DER. Then assert
`rpm -qpR` contains `kernel-core-uname-r = 7.2.5-200.fc44.x86_64`. It cannot load on your host, and
that is the point: the two kernel releases differ, which is exactly the lockstep the design exists to
respect, and that one RPM line is what makes it structural rather than a rule someone remembers.

If both pass, the rest of this design is packaging. If either fails, you have found the actual hard
part in an afternoon rather than in week six.

---

## 16. What I noticed about how you think

- You scoped the problem before asking for help: "Bluefin Dakota is good but still in Alpha, so let's
  focus on Classic now." That is a delivery decision, and it is the one that keeps the project
  finishable.
- Your read on the hardware was precise, and it holds up: "fingerprint + touchbar are MUCH better,
  sleep works etc on my Macbook Pro 16,2". Touch Bar on DRM `card0`, TouchID active with a
  fingerprint enrolled, 30 clean deep-suspend cycles in 30 days in the journal, 17 of 18 objects
  loaded on a running system. The one thing you had slightly wrong was `t2gmux` — it does not load
  here at all, and the earlier summary said it would — and you corrected it when the probe said so
  rather than defending the summary.
- You pushed back on my cost claim for A+C with a concrete counter-design rather than agreement:
  "we could implement testing gateways that write a bootable image to a USB drive … install to an
  external drive and we can boot to it, run tests, write results to a shared location and boot back."
  That is Tier 2, including the failed-boot marker the first draft was missing — and this round you
  did the harder thing and asked for the cadence to be honest instead of daily: per release, with the
  wall clock measured.
- You noticed the constraint I would have missed: "use the fact that we're running a non-mutable
  Fedora 44 so we can probably test quite a few things locally as well." That became Tier 1, and it
  is why this design has a fast loop at all.
- You kept the uncomfortable decisions rather than deferring them: sign and enrol when your own
  machine runs with Secure Boot off; claim four models when you have one on the bench; ship the
  report in v1 even though its first use will be on a machine nobody has validated. Those are the
  three that will decide whether this is a product or a fork.
