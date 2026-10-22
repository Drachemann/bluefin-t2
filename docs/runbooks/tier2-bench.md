# Tier 2 bench run — operator runbook

Tier 2 is the hardware-in-the-loop gate: install the bench image to an **external**
disk, boot it on the Mac, run the smoke test, and evaluate the artifacts the next time
the machine is back on the host. It is a **per-release** gate (design §9 Tier 2): the
claim is "no release ships without a recorded Tier 2 run", not "every build is tested".

This page is the procedure. It does not replace the design of record —
[`docs/designs/kait2en-bluefin-v2.md`](../designs/kait2en-bluefin-v2.md) §9 (Tier 2) and
R2-11 (failed-boot capture) are authoritative where this page and the design differ.

> **Status.** Three Tier 2 runs are recorded below (§0a–§0c), so this procedure is
> exercised on hardware. The harness's own behaviour is covered by `harness/selftest.sh`
> (84 cases: every refusal, every R2-11 branch, a full boot-side run against a fake
> results stick). A new run still gets its digest and date recorded in §0a–§0c.

## 0. Current state (2026-10-20)

The bench image exists and passes all sixteen Tier 0 gates (11 the T7 units, 12 the report
and `models.d`, 13 the apps and `t2remote`, 14 SELinux/PAM/icons, 15 the shipped docs,
16 the hub) plus `bootc container lint` (14 passed, 1 skipped, 0 warnings at the last
2026-10-21 build). It has **not** been installed or booted.

| | |
|---|---|
| Image | `localhost/bluefin-t2-bench:7.2.5-200.fc44.x86_64` |
| Digest | `sha256:b182e934b3366383f5770dc913f03ec2ed49b4ae75a734efce4f25cc6cf7657e` |
| Rootfs size | 7.3 GiB (`{{.Size}}` = 7 840 768 831 B) |
| KVER | `7.2.5-200.fc44.x86_64` |
| Ships | 18 signed modules, the rebuilt initramfs, 13 kargs, `models.d/MacBookPro16,2.toml`, and the harness layer (gate 10 proves the last three) |

The detailed gate list and artifact inventory from the first build are preserved at
[`docs/evidence/artifact2-bench-slice.md`](../evidence/artifact2-bench-slice.md) (image ids
there are the 2026-10-20 build's; later rebuilds changed the id, not the gates).

**Two devices are required, and that is the one thing this bench currently lacks:**

- a **target** disk the image fits on (≥ 16 GiB; a 32 GiB stick works, 28.8 GiB usable), and
- a **results** medium, FAT32, labelled `K2B-HIL`, on a *different* disk.

They cannot be the same disk: `bootc install to-disk` claims the whole target, and the
booted test system must be able to mount the results medium — which it cannot do if that
medium is a partition of the disk it just booted from. The single-disk layout exists
(manual partitioning plus `bootc install to-filesystem`) and is documented in the design
as an option, **not** the default; the harness implements `to-disk` only.

`/dev/sda` is currently a 32 GiB `TransMemory` stick. Its contents are unknown to the agent
session (no read permission on the block device), so **check what is on it before
formatting anything**.

---

## 0a. The first recorded Tier 2 run (2026-10-21)

| | |
|---|---|
| Run id | `20261020T154022Z-7f56` |
| Image | `localhost/bluefin-t2-bench@sha256:64035fde…` (loaded manifest; built as `b182e934…`) |
| Booted kernel | `7.2.5-200.fc44.x86_64` — the image's kernel, correctly |
| Stage log | 2 lines: `sysinit.target`, `multi-user.target` |
| Verdict | **FAIL** — `modules`, `systemd_failed` |
| Wi-Fi | **pass** — `wlp229s0` connected to `Nakama`; the `/var/lib/firmware/brcm` copy and `firmware_class.path` work |
| Modules | 16/18 loaded; `t2bce_ave` and `t2bdrm` missing |

What this run proved: the image boots on the hardware, userspace is reached, the deployed
kernel is the image's kernel, and the per-machine firmware path works. What it did not
prove: the full module set, and a clean systemd state.

Both module misses were slice omissions, not module defects — `t2bce_ave` has no modalias
and KAIT2EN modprobes it from its userspace (`kait2en-t2-remote.service`), while `t2bdrm`'s
USB modalias matches a device that only appears once the BCE stack is up. Both are now in
`modules-load.d/90-t2.conf` and the image was rebuilt as `sha256:64d35edc…`.

The two failed units (`rpc-statd-notify.service`, `user@NR.service`) were captured by name
only; the smoke test now records `unit_logs` for each failed unit so the next run explains
itself instead of needing a guess.

Reported on the hardware: Wi-Fi connected; Touch Bar showed the *stock* row (expected — the
enhanced Touch Bar is userspace the slice does not ship, and `t2bdrm` was not loaded);
external keyboard and trackpad worked; the **internal trackpad did not** — that is a real
symptom for the next run, not explained by the two missing modules (t2_precision_trackpad,
t2_trackpad_actuator and t2bce_vhci all loaded).

---

## 0b. Second run (2026-10-21, after the module-load fix)

| | |
|---|---|
| Run id | `20261020T164431Z-235e` |
| Image | `localhost/bluefin-t2-bench@sha256:86c7ffdf…` (built as `64d35edc…`) |
| Kernel | `7.2.5-200.fc44.x86_64` |
| Modules | **pass** — 18/18, no unexpected objects |
| `systemd_failed` | **pass** — no failed units |
| Stages | 2 lines |
| Wi-Fi | **fail** — `not-associated-after-60s` |
| Verdict | **FAIL** — `wifi` only |

The module fix worked: adding `t2bce_ave` and `t2bdrm` to `modules-load.d` took the set
from 16/18 to 18/18, and the two failed units from run 1 did not recur (they were session /
environment transient, not image defects).

The Wi-Fi failure was **operator setup, not hardware**: `/var/lib/firmware` did not exist on
the target, because a reinstall wipes `/var` and the per-machine firmware copy was not
repeated. That is the trap this section exists for.

It also exposed a **vacuous assertion**: the firmware check greps for the literal
`firmware load failed`, but brcmfmac reports `Direct firmware load for … failed with error
-2`, so it scored `ok` with no firmware present at all. The smoke test now matches the
message family and additionally requires a `phy80211` interface to exist. Design §9's
wording is too narrow and is corrected in `research/findings/module-pipeline.md` §6.

The rebuilt image adds that fix and records `observed.input_devices` (names from
`/proc/bus/input/devices`) so the unresolved **internal trackpad** symptom from run 1 can be
diagnosed from evidence rather than from a guess.

---

## 0c. Third run (2026-10-21) — hardware green, one environmental red

| | |
|---|---|
| Run id | `20261020T215251Z-3852` |
| Image | `localhost/bluefin-t2-bench@sha256:a51bebe4…` (built `eddfa517…`) |
| Kernel | `7.2.5-200.fc44.x86_64` |
| Modules | **pass** — 18/18 |
| Firmware | **pass** — no load failures; `interfaces: ["wlp229s0"]` |
| Wi-Fi | **pass** |
| `systemd_failed` | **fail** — `gssproxy.service`, `rpc-statd-notify.service` |
| Verdict | **FAIL** — `systemd_failed` only |

Reported on hardware for this run: internal keyboard and internal trackpad worked, and so
did an external USB keyboard and both a USB and a Bluetooth trackpad.

The two failed units both **timed out** rather than crashed, and both sit in the network /
NFS stack: `gssproxy` is `After=network.target`, `rpc-statd-notify` is
`After=network-online.target nss-lookup.target`. The capture (added after run 2) shows
`start operation timed out` for each, at 46 s and 60 s into the boot. The same image passed
this assertion on the two earlier boots — which are exactly the boots where Wi-Fi never came
up, i.e. where the network path was not exercised. So the failure correlates with the
network coming up, not with the T2 stack, and it is intermittent.

**Decision (recorded, not hidden):** the assertion stays strict. These units are in the
release image too, and a user whose Wi-Fi associates slowly could see the same thing, so
masking them in the bench slice would hide a real question rather than answer it. The bench
record therefore says "hardware green, systemd_failed red, cause understood and environmental
for this slice". Whether the release needs a fix (a shorter `network-online` wait, a unit
ordering change, or accepting the timeouts) is a release-image question for its own Tier 2
run.

Small pending improvement: the unit capture now takes 20 journal lines instead of 6, so a
recurrence carries the service's own output, not just systemd's summary.

---

## 0d. Fourth run (2026-10-21/22) — the userspace layer, one retried boot

**PASS** on the four hard assertions (modules, firmware, Wi-Fi on `wlp229s0`, no failed
units), image `sha256:a17cd966…`, KVER `7.2.5-200.fc44.x86_64`, run
`20261021T113631Z-22a5`. The full record, including five defects and what was fixed, is
[`docs/evidence/tier2-run-2026-10-22.md`](../evidence/tier2-run-2026-10-22.md).

Two operational lessons from this run are now part of the procedure below:

- **A retried boot is normal.** `stages.log` may hold more than one boot; `evaluate.sh`
  reads the last boot and records `stages.boots`. Do not trim the log.
- **`systemctl --root` cannot mask a unit for a bootc deployment.** The booted `/etc` is the
  deployment's etc, not the top-level `etc/` an offline mount shows. For an interactive boot,
  use the GRUB kernel argument described in §3.8.

## 1. What the harness is

| File | Runs where | Job |
|---|---|---|
| `harness/selftest.sh` | host | proves the harness logic with synthetic fixtures; run it before spending a bench slot |
| `harness/install-to-disk.sh` | host (as root) | guarded wrapper around `podman … bootc install to-disk`; refuses everything that is not an external whole disk, resolves the image to a digest, writes `install-receipt.json` |
| `harness/attempt.sh` | host (as you) | writes `attempt.json` **before power-on**; the digest/KVER/target/Secure-Boot record. Refuses to overwrite a previous attempt |
| `harness/rootfs/…` | the installed image | the three harness-only units, the two stage loggers and the smoke test |
| `harness/evaluate.sh` | host | the four R2-11 outcome branches, the photograph requirement, and the digest/KVER integrity gates |

The three artifacts are monotone, each written by a different layer, so the *absence* of
the next one localises the failure (R2-11):

| Artifact | Written by | When | Proves |
|---|---|---|---|
| `runs/<id>/attempt.json` | `attempt.sh` on the host | before power-on | the run existed, and what was meant to boot |
| `runs/<id>/stages.log` | the booted image, at `sysinit.target` then `multi-user.target` | during boot | kernel + initramfs completed; userspace reached each stage |
| `runs/<id>/result.json` | the booted image, smoke test, then it powers off | after the test | the run finished, and the smoke assertions |

Results live on a **dedicated results stick**, never on the install target: `bootc
install to-disk` claims and repartitions its whole device, and the internal root is LUKS.

---

## 2. Prerequisites

### Human gates — stop if any is missing

- [ ] **Explicit permission to erase the external disk.** It is destroyed, not shrunk.
      Back up anything on it first.
      *On this bench machine the current external candidate is `/dev/sda`, a
      USB-attached `TOSHIBA MQ04ABF100` (931.5 GB) whose `sda1` is an ext4 filesystem
      labelled `StayHuman`, 922 GB, currently unmounted. Assume it holds data.*
- [ ] **A decision on Secure Boot.** Its state is recorded in `attempt.json`, but if the
      modules' DER is not enrolled and Secure Boot is on, the keyboard modules will not
      load. Enrolment is a separate, human decision — see the design §5 signing key
      lifecycle. Do not "fix" a Secure Boot failure by disabling a signature check.
- [ ] **Permission to power-cycle the Mac** and to boot an external disk via Option.

### Hardware

- [ ] The Mac under test (currently `MacBookPro16,2`; `15,2`/`15,4` need their own runs).
- [ ] An **external whole disk** on USB. A USB-attached SATA bridge is fine: the guard
      checks USB transport ancestry, not the `removable` flag, precisely because such a
      bridge reports `removable=0`.
- [ ] A **results stick**, FAT32, filesystem label **`K2B-HIL`**. The booted system
      mounts it by that label at `/var/mnt/hil`; a different label fails the run.
      It must be a different *disk* from the install target (the guard enforces this).
- [ ] The **firmware payload** for this machine (the four files and `SHA256SUMS`),
      captured from the running macOS by the kit. Without it, Wi-Fi will fail the smoke
      test. Apple firmware is per-machine and never goes into the image.

### Software and image

- [ ] The bench image, `localhost/bluefin-t2-bench:<tag>`, built by the bench pipeline,
      carrying the label `ostree.linux=<target KVER>`.
- [ ] `podman`, `skopeo`, `jq` and `mokutil` on the host.
- [ ] The image is visible to **rootful** podman (the install runs as root, because a
      rootless container cannot write a block device). If the image was built rootless,
      move it without rebuilding:

      ```sh
      rm -f /var/tmp/bluefin-t2-bench.tar     # docker-archive will not overwrite
      podman save -o /var/tmp/bluefin-t2-bench.tar localhost/bluefin-t2-bench:<tag>
      sudo podman load -i /var/tmp/bluefin-t2-bench.tar
      # /tmp is a 7.8G tmpfs on the bench host — the 7.3GiB archive does not fit there.
      ```

### The bench image contract

The bench image is the release image **plus** a harness layer, and the layer is the only
difference:

- [ ] `COPY harness/rootfs/ /` — the units land in `/usr/lib/systemd/system/`, the
      scripts in `/usr/libexec/bluefin-t2-hil/`.
- [ ] The units are enabled. `harness/rootfs/etc/systemd/system/*.target.wants/` ships
      them as symlinks, so a plain `COPY` is enough; `systemctl preset-all` also works
      (a preset file is shipped).
- [ ] `/usr/share/bluefin-t2/models.d/<ProductName>.toml` exists with the three
      categories, e.g. for `MacBookPro16,2`:

      ```toml
      status           = "validated"   # validated | validation-set | argument
      expected_loaded  = ["t2bce_dma", "t2bce_core", "t2bce_vhci", "t2bce_audio",
                          "t2bce_ave", "t2hid", "t2touchbar_bl", "t2touchbar_kbd",
                          "t2bdrm", "t2smc", "t2smp", "t2sbs", "t2thunderbolt",
                          "t2mfi_fastcharge", "t2_precision_trackpad", "t2_trackpad_actuator"]
      expected_unbound = ["hid_t2magicmouse"]
      expected_absent  = ["t2gmux"]
      ```

      A literal `"unmeasured"` inside a list is skipped and recorded. A missing file or
      category fails the modules assertion — that is the named-set rule, not a warning.
- [ ] The `ostree.linux` label names the kernel the modules were built for.

### The bench slice is not the release image

The bench Containerfile is deliberately a slice: kmods, kargs, dracut `force_drivers`,
the initramfs, and nothing else. That is the right shape for a boot-path question, and it
changes this run in three ways:

- **It must also copy the harness layer** (`COPY harness/rootfs/ /`). Without it no stage
  line and no smoke test exist: the run ends as `FAILED_BOOT` (the early unit is absent
  entirely) or `HARNESS_ERROR` (the attempt exists but nothing ever wrote). This is an
  image requirement, not an optional extra, and it is the one difference between the
  bench image and the release image that the record must name.
- **It must ship `models.d`.** The smoke test asserts the named set from
  `/usr/share/bluefin-t2/models.d/<ProductName>.toml`. With the file absent the modules
  assertion fails with `reason: models.d-missing:<model>` and the run reports `FAIL` —
  correctly, because the image is incomplete. Copy
  `system_files/usr/share/bluefin-t2/models.d/` into the bench slice; the release image
  ships the same data.
- **It carries the firmware import units now.** `bluefin-t2-firmware-import.{service,path}`
  and the T7 units are part of `system_files/`, so the slice ships them. With no ESP
  payload they are no-ops; if you place the payload on the ESP the import path runs for
  real. Writing the files straight into `/var/lib/firmware` (§3.6 method B) still works and
  is what the recorded runs did.

The slice ships the inherited apps, `t2remote`, `bluefin-t2 report` and the T7 units, but
it has no hub, no SELinux module and no PAM fingerprint. A bench run logs no desktop
session, so the per-user unit and the GUI apps are not exercised even though they are
present; the daemons do start at boot and `systemctl --failed` covers them. §6 says what
the run does not prove.

---

## 3. The run, in order

Work from the repository root on the internal system. `$RESULTS` is the mounted stick.

### 3.1 Prove the harness first

```sh
harness/selftest.sh
# expected: "failed: 0". Skips are reported with a reason and are acceptable: they appear
# when no unmounted external whole disk exists to use as a refusal fixture (the results
# disk is mounted during a real run, and a broken stick reports 0 bytes).
```

A failing selftest means a harness fault; do not spend a bench slot on it.

### 3.2 Confirm the image and its kernel

```sh
podman images localhost/bluefin-t2-bench
skopeo inspect --no-tags containers-storage:localhost/bluefin-t2-bench:<tag> \
  | jq -r '.Digest, .Labels["ostree.linux"]'
```

You need a `sha256:` digest and the KVER the image was built for. A missing label means
`attempt.sh` will require `--kver`; fix the image rather than typing the kernel from
memory.

### 3.3 Prepare and mount the results stick

Formatting **destroys the stick**. Check the device path twice.

```sh
lsblk -o NAME,PATH,SIZE,TRAN,FSTYPE,LABEL
sudo mkfs.vfat -F 32 -n K2B-HIL /dev/sdX        # the STICK, not the install target
```

Mount it (Files app, or `udisksctl mount -b /dev/sdX1`) and set:

```sh
RESULTS=/run/media/$USER/K2B-HIL
findmnt -no TARGET,FSTYPE,LABEL "$RESULTS"      # vfat, K2B-HIL
mkdir -p "$RESULTS/runs"
```

### 3.4 Dry-run the installer

`--dry-run` resolves the digest, runs every refusal, and prints the exact command — it
writes nothing and runs nothing. It still requires `CONFIRM`, because the same guard
path is being exercised.

```sh
sudo env CONFIRM=/dev/sda harness/install-to-disk.sh --dry-run \
  --image localhost/bluefin-t2-bench:<tag> \
  --device /dev/sda \
  --results-root "$RESULTS"
```

Read the plan before continuing. The lines that matter:

```
  image digest:      sha256:…            ← the recorded artifact identity
  pinned source:     containers-storage:localhost/bluefin-t2-bench@sha256:…
  kver label:        7.2.5-200.fc44.x86_64
  target device:     /dev/sda
  external proof:    sysfs-usb           ← why it is allowed to be a target
  mounted parts:     none (checked)
  results root:      … (label 'K2B-HIL', vfat, disk sdX)   ← a different disk
```

### 3.5 Install (this erases the target disk)

The token is the whole safety interlock: type the device.

```sh
sudo env CONFIRM=/dev/sda harness/install-to-disk.sh --execute \
  --image localhost/bluefin-t2-bench:<tag> \
  --device /dev/sda \
  --results-root "$RESULTS"
```

The script never calls `sudo` itself; run it under `sudo`. On success it prints the run
directory and writes `runs/<id>/install-receipt.json` (digest, pinned source, KVER,
target, bootc-image pin, exact command). **Copy the run id** — the next step needs it.

If it refuses, read the named error (§7). Every refusal is a designed interlock; a guard
that "only gets in the way" is the one that keeps the internal disk alive.

### 3.6 Put the firmware payload on the target, before first boot

Without this the Wi-Fi assertion fails, and the run says nothing useful about the radio.
The payload is per-machine, captured from the running macOS by the kit, and it stays on
this disk. It is never committed to the image.

**Decided 2026-10-21:** the channel installs the payload under **both** the board-qualified
and the generic base names (see the copy step below). The bench kernel asks for the generic
name and failed with qualified-only files; the qualified copies are harmless alongside.

**On a MacBookPro16,2 the four files are** (they are owned by no package on the host,
i.e. placed by hand from macOS — which is why they are not in the image):

```
brcmfmac4364b3-pcie.apple,trinidad-HRPN-u-7.7.txt
brcmfmac4364b3-pcie.apple,trinidad-HRPN-u-7.7-X3.bin
brcmfmac4364b3-pcie.apple,trinidad-X3.clm_blob
brcmfmac4364b3-pcie.apple,trinidad-X3.txcap_blob
```

**Method A — bench slice (no import service), write the kernel's search path directly.**
`firmware_class.path=/var/lib/firmware` is in the kargs (verified in the installed
`/boot/loader/entries/ostree-1.conf` on 2026-10-21), so the firmware goes in the target's
persistent `/var`.

`bootc install to-disk` on btrfs does **not** give you a plain root tree: `/` is composefs,
the mounted filesystem holds `boot/` and `ostree/`, and the persistent `/var` is
`ostree/deploy/<os>/var` on the target filesystem. Mounting "the root partition" and
writing `etc/` there will not work. The persistent `/var` is what you want:

Preferred — one command, and it refuses the silent failure modes:

```sh
sudo harness/provision-firmware.sh --target-root /run/media/matt/root --require-count 8
```

It refuses a path that is not a mount (`E_NOT_MOUNTED`), a mount without
`ostree/deploy/*/var` (`E_NO_VAR`), and a missing payload (`E_NO_SOURCE`); it copies the
board-qualified files and the generic base names, then **verifies every file landed**. The
manual equivalent is below if you want to see each step.

```sh
R=/run/media/matt/root          # the target filesystem, auto-mounted by label 'root'
findmnt -no SOURCE,TARGET "$R"  # MUST print /dev/sda3 — if it prints nothing, STOP
VAR="$R/ostree/deploy/default/var"
test -d "$VAR" || { echo "no persistent /var there — wrong mount, do not copy"; exit 1; }

D="$VAR/lib/firmware/brcm"
sudo mkdir -p "$D"
sudo cp -a /lib/firmware/brcm/brcmfmac4364b3-pcie.apple,trinidad-* "$D"/

# The bench kernel (7.2.5) asks for the UNQUALIFIED base name, unlike the working host.
# Install both forms; see research/findings/module-pipeline.md §7.
cd "$D"
sudo cp -v 'brcmfmac4364b3-pcie.apple,trinidad-HRPN-u-7.7-X3.bin' brcmfmac4364b3-pcie.bin
sudo cp -v 'brcmfmac4364b3-pcie.apple,trinidad-X3.clm_blob'      brcmfmac4364b3-pcie.clm_blob
sudo cp -v 'brcmfmac4364b3-pcie.apple,trinidad-X3.txcap_blob'    brcmfmac4364b3-pcie.txcap_blob
sudo cp -v 'brcmfmac4364b3-pcie.apple,trinidad-HRPN-u-7.7.txt'   brcmfmac4364b3-pcie.txt

ls -l "$D"                      # expect 8 files: 4 qualified + 4 generic
sync
```

Verify the deployment before booting (these are the pre-boot proofs):

```sh
sudo sha256sum "$R"/boot/ostree/*/initramfs-*.img   # must equal the image's initramfs
sudo lsinitrd "$R"/boot/ostree/*/initramfs-*.img \
  | grep -E '/(t2bce_dma|t2bce_core|t2bce_vhci|t2hid|t2smc|t2sbs)\.ko'   # expect six
sudo grep -o 'firmware_class.path=[^ ]*' "$R"/boot/loader/entries/ostree-1.conf
```

> Layout note: on the bench image the `/boot` you see is the ostree boot directory on the
> btrfs volume, and `.bootc-aleph.json` records the **installer container's** kernel
> (the host's `7.2.11`) rather than the deployed `7.2.5`. The deployed kernel is what
> `/boot/ostree/*/vmlinuz-*` and the loader entry name; do not read the aleph field as
> the image's kernel.

**Method B — an image with the import path (the design's shape): pre-place on the ESP**
so `bluefin-t2-firmware-import.service` exercises its real path on first boot:

```sh
lsblk -f /dev/sda
sudo mkdir -p /mnt/target-esp
sudo mount /dev/sda1 /mnt/target-esp            # the vfat ESP on the TARGET disk
sudo mkdir -p /mnt/target-esp/kait2en/firmware/wifi
sudo cp -a <payload>/. /mnt/target-esp/kait2en/firmware/wifi/
( cd /mnt/target-esp/kait2en/firmware/wifi && sha256sum -c SHA256SUMS )
sudo umount /mnt/target-esp
```

Method B does not prove the import path on a slice that lacks the import unit; say which
method was used when reporting the run.

### 3.7 Write the attempt record — before power-on

```sh
harness/attempt.sh --results-root "$RESULTS" --run-id <id from 3.5> --boot-target /dev/sda
```

It cross-checks the install receipt (digest, KVER, target) and refuses a disagreement.
It marks the run current on the stick (`CURRENT`), which is how the booted system finds
the right run directory. On success:

```
attempt recorded: …/runs/<id>/attempt.json
  image:        localhost/bluefin-t2-bench:<tag>@sha256:…
  kver:         7.2.5-200.fc44.x86_64
  boot target:  /dev/sda (…, sysfs-usb)
  secure boot:  disabled
  timeout:      900s
  photograph:   null (required only if the next boot dies before sysinit)
```

### 3.8 Boot the external disk

1. Power the machine off.
2. At the chime hold **Option (⌥)** and choose the external disk's EFI entry.
3. Leave it alone for up to the recorded timeout (900 s default). On the success path
   the smoke test writes `result.json` and **powers the machine off by itself**.

**If it visibly fails** (no Apple logo, a black screen, a kernel panic, a recovery
prompt): that is very likely the `FAILED_BOOT` class. **Photograph the screen now** —
a T2 Mac has no serial console and there is no other capture path — then power off
manually and go to §3.10.

### 3.8a Interactive boot (for the checks the smoke test cannot make)

From the 2026-10-22 image onward the smoke test powers off **only** when the run wrote a
`POWEROFF` marker. `attempt.sh` writes it for a scored run; `attempt.sh --interactive`
records the attempt without it, so the same boot continues into the session. That is the
normal way to do this: one boot, no kernel argument, no power cycle — and a power loss
costs a macOS boot before Touch ID works again.

For an older image, or to force it, mask the unit for the boot. An offline
`systemctl --root=$MOUNT mask` does **not** reach the booted deployment's `/etc` (the
2026-10-22 defect); either write the mask under the deployment's own `etc/` (the
`fix-interactive-boot.sh` on the results stick does this and verifies it), or append
`systemd.mask=bluefin-t2-hil-test.service` to the GRUB `linux` line.

Then, in the session:

1. Log in as the account onboarding created.
2. Check the group: `id -nG | grep -q kait2en-touchbar && echo in-group || echo MISSING`.
   The 2026-10-22 image does this from `bluefin-t2-user-groups.service` plus its path unit on
   `/etc/passwd`; a session that started before `usermod` ran needs one log out/in.
3. Run the one-shot script from the results stick — it captures the evidence, runs
   `interactive-checks`, writes the firmware marker and prints the TODO list:

   ```
   /var/mnt/hil/bench-interactive.sh
   ```

   (source `harness/bench-interactive.sh`; if the stick is not mounted at `/var/mnt/hil`,
   open it in Files and run `/run/media/$USER/K2B-HIL/bench-interactive.sh`). It writes
   `interactive-<run-id>.log` and `report-<run-id>.json` next to itself.
4. Do **not** power off to finish: reboot to the internal system (or leave the machine for
   the next stage). A power cut/panic puts the T2 into the state where Touch ID is disabled
   until the next macOS login.

Touch ID specifically: nothing is enrolled on Linux. A finger must be enrolled under macOS,
the SEP biometric keybag must have been unlocked by a macOS login once since the T2 last
*powered off* (rebooting does not power-cycle the T2), and the T2 CDC-NCM link must be up.
The bridge binds the macOS-enrolled finger to the Linux account itself; `fprintd-enroll` is
only the fallback. If `fprintd-list` is empty despite an enrolled finger, check, in order:
`journalctl -b -u kait2en-t2-touchid` (must not say "cannot reach the sensor"), the link's
IPv6 (`ip -6 addr show <cdc_ncm> | grep fe80`), and that NetworkManager's "Apple T2 Bridge"
profile has `autoconnect=true`. A profile created by the 2026-10-22 helper had
`autoconnect=no`; `fix-t2-ncm.sh` on the results stick repairs it offline.

### 3.9 Come back to the internal system

Power on normally. If the external disk is still selected, hold Option and choose the
internal Fedora entry. Insert the results stick and confirm it is mounted again
(`findmnt "$RESULTS"`).

### 3.10 Evaluate

```sh
harness/evaluate.sh --results-root "$RESULTS"
# or, exactly one run:
harness/evaluate.sh --run-dir "$RESULTS/runs/<id>"
```

The evaluator writes `verdict.json` into the run directory and exits with the outcome
code (§4). It is read-only apart from that verdict, except that a `FAILED_BOOT` run
requires a photograph to close:

```sh
harness/evaluate.sh --run-dir "$RESULTS/runs/<id>" --photograph ~/bench-photo.jpg
```

The photograph is copied into the run directory, hashed, and recorded in
`attempt.json`; until then the evaluator exits 20 and writes nothing.

### 3.11 The record

A Tier 2 result is only useful if it is tied to an artifact. Keep the whole run
directory:

- `install-receipt.json` — what was installed, from which digest
- `attempt.json` — what was meant to boot, and the Secure Boot state
- `stages.log` — how far boot got
- `result.json` — the smoke assertions
- `verdict.json` — the outcome, and any photograph

A model becomes **validated on hardware** only when a digest-pinned Tier 2 run for
*that* model is recorded (design §4). Promoting a model is a human decision; no amount of
green harness output substitutes for the run. State the digest, the KVER, the model and
the date when you make the claim.

---

## 4. Reading the outcome

| Outcome | Exit | Artifacts present | Meaning | Next |
|---|---|---|---|---|
| `PASS` | 0 | attempt + 2 stage lines + result (`status: pass`) | the image booted and all four smoke assertions passed | record the run; this is the gate that counts |
| `FAIL` | 1 | attempt + 2 stage lines + result (`status: fail`) | it booted; at least one assertion failed | read `result.json.assertions.*.missing` / `.matches`; that is a product bug, not a harness bug |
| `FAILED_USERSPACE` | 2 | attempt + 1 stage line, no result | kernel/initramfs finished; userspace died or hung before the test ran | console/photo the screen at the point it stopped; suspect userspace, not the module build |
| `FAILED_BOOT` | 3 | attempt, no stage log | the kernel or initramfs never reached `sysinit.target` | the photograph is mandatory; suspect the kernel/initramfs (the keyboard-module class) |
| `HARNESS_ERROR` | 4 | anything inconsistent | the *harness* is at fault: no attempt, unreadable artifacts, a digest/KVER mismatch, or a result that contradicts itself | fix the harness or re-run; do not read it as a hardware result |
| `UNCLOSED` | 20 | `FAILED_BOOT` without a photograph | refusal: the run is not allowed to close | attach a photograph (§3.10) |

Two R2-11 branches have no separate code but are handled explicitly:

- **2 stage lines, no `result.json`** → `FAILED_USERSPACE`, reason
  `smoke-test-did-not-complete`. The design does not name this combination; userspace
  clearly ran, so it is not `FAILED_BOOT`.
- **A `stages.log` with only a `multi-user.target` line, an empty log, or garbage** →
  `HARNESS_ERROR`. The monotone order is broken, so the log cannot localise the failure;
  the most likely cause is the results stick not being mounted at sysinit, which is a
  harness fault, not hardware.

---

## 5. Recovery contract

This procedure never writes to the internal disk. The guards refuse it; do not work
around them.

- **Boot back to the existing system:** power on (or hold Option and choose the internal
  entry). The internal Fedora installation is untouched.
- **If the external disk won't boot:** that is the experiment failing, not the machine.
  Option-boot the internal entry and keep the run directory; a `FAILED_BOOT` record plus
  a photograph is a useful result.
- **If nothing boots:** macOS Recovery (⌘R at the chime). The internal disk was not a
  target, so Recovery can still mount it. The previous deployment is pinned and
  untouched; do not run `bootc upgrade` or any repair on the internal system during a
  bench.
- **Never unload the input modules on the running T2 Mac.** `t2hid`, `t2bce_*` and
  `hid_t2magicmouse` carry the internal keyboard and trackpad. Unloading them on the
  machine you are working *from* locks the owner out of a laptop that then needs
  external hardware to recover. (`t2smc`, `t2thunderbolt`, `t2mfi_fastcharge` and `t2smp`
  are the safe set — see `AGENTS.md`.)
- **Never install to the internal disk.** `/dev/nvme0n1` and every partition of it, and
  every disk backing `/`, `/boot`, `/boot/efi` or `/home`, is refused by name.

---

## 6. What this run does **not** prove

State this section whenever the run is reported. A green Tier 2 run is not a release.

- **Not the release image.** The run boots the *bench* image, which is the release image
  plus that layer — three harness-only units and two scripts under
  `/usr/libexec/bluefin-t2-hil/`. The bench image digest is recorded, but the release
  digest is not the thing that booted.
- **Not any other model.** `MacBookPro15,2`, `15,4` and `16,3` each need their own
  digest-pinned run. `16,3` is supported by argument only.
- **Not the kit or the ISO (Tier 3).** There is no macOS firmware capture, no GRUB
  rewrite, no ESP initramfs injection, and no install with no external hardware attached.
- **Not these design smoke items**, which this harness does not score (it records only
  what can be measured without a session):
  - Touch Bar usable **as the desktop user** — needs a logged-in session
  - `fprintd-list` non-empty / fingerprint offered at the lock screen — needs a user
  - one suspend/resume cycle — cannot be driven safely from a boot oneshot, and a hung
    suspend would destroy the run's own evidence
  - the DSP sink in `wpctl status` — needs the user's PipeWire session
  - Bluetooth (the open `15,2` question) is **not** asserted
- **Not Secure Boot enforcement.** The state is recorded; unless the run was performed
  with Secure Boot on and our DER enrolled, the Secure Boot path is unproven.
- **Not upgrades or rollback.** `bootc upgrade`, the previous-deployment rollback and the
  signing-rotation drill are separate (T15).
- **Not firmware import failure modes.** A wrong-board payload, a full ESP or a payload
  pulled mid-install are Tier 3 negative runs.
- **Not general reliability.** One boot, one model, one digest, one KVER. No thermal,
  battery, Wi-Fi roaming or repeat-suspend claim follows from it.
- **Not the user experience.** First-login provisioning, the hub app and the report are
  not exercised by this harness.

The harness itself is proven by `harness/selftest.sh` (84 cases), and that proves the
harness logic — not the hardware, the image or the kit.

---

## Troubleshooting

**`jq: parse error: Invalid literal at line 1, column 6`** — this was a harness bug, fixed
2026-10-21: `hc_image_inspect_json` merged `skopeo`'s stderr into its stdout, and as root
skopeo logs `time="…" level=warning …` there, which is not JSON. It now keeps stderr
separate and prints it as a warning. If you see this shape again, run the inspect by hand
and look for a log line before the `{`:

```sh
skopeo inspect --no-tags containers-storage:localhost/bluefin-t2-bench:<tag> | head -1
```

**`bootc install to-disk` fails with `Creating rootfs: No install configuration found, and no filesystem specified`**
— the image ships no `/usr/lib/bootc/install/*.toml` (Bluefin's does not either), so bootc
1.17.1 has no default root filesystem to use. The harness now passes
`--filesystem btrfs --wipe` explicitly (`--root-fs` overrides the filesystem). This is a
deliberate harness-level fix rather than an image config: the flag is visible in the plan
and in the receipt's command. Verified 2026-10-21 — the first attempt failed here, after
repartitioning the target.

**`mkfs.btrfs` fails: `/dev/sdaN appears to contain an existing filesystem (type=btrfs, label=root) … use -f`**
— bootc's `--wipe` clears the partition table and whole-disk signatures, but **not** a
filesystem superblock sitting where a new partition lands. A second attempt hits this as
soon as a first attempt got as far as `mkfs`. The harness now runs `wipefs -a` on every
existing partition and on the disk before invoking bootc (execute mode only). To do it by
hand: `sudo wipefs -a /dev/sdXN /dev/sdX`. Verified 2026-10-21 — this was the second
install failure, after the missing `--filesystem`.

**`podman save` fails: `docker-archive doesn't support modifying existing images`**
— a tarball from a previous build is still at the destination. `podman save` appends to a
docker-archive; it will not replace one. `rm -f` the path (or save to a new filename)
first. Hit 2026-10-21 on the second cycle.

**The target reports `0B`** — the kernel will say `detected capacity change from N to 0`.
That is the stick dropping out, not a software fault. Re-seat it (different port if
possible; prefer a port on the machine, not a hub) and confirm with
`lsblk -b -d -o NAME,SIZE,MODEL /dev/sdX` before retrying.

## 7. Named errors

`install-to-disk.sh` — every one is a refusal, and each is meant to stop the run:

| Error | Cause | Action |
|---|---|---|
| `E_INTERNAL_DISK` | the target is `/dev/nvme0n1`, a partition of it, or the disk backing `/`, `/boot`, `/boot/efi`, `/home` | name the external disk; never work around this |
| `E_PARTITION` | a partition was passed instead of a whole disk | pass `/dev/sda`, not `/dev/sda1` |
| `E_NOT_WHOLE_DISK` | a dm/loop/other block device | pass the whole disk |
| `E_NOT_USB` | the parent is neither USB transport nor removable | the target must be the external USB disk |
| `E_TARGET_EMPTY` | the target reports 0 bytes — it dropped out or has no media (`kernel: sdb: detected capacity change ... to 0`) | re-seat the device, check `lsblk -b -d /dev/sdX`, then retry |
| `E_TARGET_TOO_SMALL` | the target is smaller than the image's root filesystem | use a larger disk |
| `E_MOUNTED` | the disk or something under it is mounted, or is swap | unmount every partition on the target |
| `E_DEVICE_MISSING` / `E_NOT_BLOCK` | no such device / not a block device | check the path |
| `E_CONFIRM_MISSING` / `E_CONFIRM_MISMATCH` | the `CONFIRM=<device>` token is absent or names another device | set `CONFIRM` to the same device you passed |
| `E_NO_IMAGE` / `E_NO_DEVICE` / `E_NO_RESULTS_ROOT` | an omitted argument — there is no default | pass it explicitly |
| `E_DIGEST_UNRESOLVED` | `skopeo` cannot pin the image (or a rootless-built image is invisible to root) | build/pull into rootful storage (§2) |
| `E_RESULTS_ON_TARGET` | results on the same disk as the target | use the separate stick |
| `E_RESULTS_LABEL` | the results stick is not labelled `K2B-HIL` | relabel it, or the booted system cannot mount it |
| `E_RESULTS_NOT_REMOVABLE` | results on non-removable storage | use the stick |
| `E_NOT_ROOT` | `--execute` without root | run under `sudo` |
| `E_BOOTC_UNPINNED` | the bootc container image could not be pinned | `podman pull quay.io/fedora/fedora-bootc:44`, or accept explicitly with `--allow-floating-bootc` |
| `E_RUN_EXISTS` | the run directory already exists | a run is never reused; use a new run id |

`attempt.sh` and `evaluate.sh` add `E_RUN_MISSING`, `E_NO_DIGEST`, `E_NO_KVER`,
`E_DIGEST_MISMATCH`, `E_KVER_MISMATCH`, `E_TARGET_MISMATCH`, `E_ATTEMPT_EXISTS`,
`E_NOT_CLOSED`, `E_PHOTOGRAPH_MISSING`, and the `HARNESS_ERROR` reasons above.

---

## 8. Harness decisions worth knowing

These are the places where the implementation had to interpret R2-11 or the design; they
are deliberate, and they are all tested by `harness/selftest.sh`:

- **The results stick is mounted by the loggers, not by a separate mount unit.** The
  design says "a harness unit"; the implementation does the mount inside `lib.sh` so one
  writer owns the stick, the wait is bounded (30 s at sysinit, 60 s later), and there is no
  ordering knot between a `local-fs.target` mount and the `Before=sysinit.target` marker.
  If the stick cannot be mounted at sysinit, no stage line is written and the run looks
  like `FAILED_BOOT`; the photograph disambiguates, and the wait is visible in the stage
  line's `uptime`, so a slow stick inflates the sysinit timestamp.
- **`CURRENT` on the stick names the run being booted.** It is written by `attempt.sh`
  (atomically, fsynced). The booted side uses it, falling back to the newest
  `runs/*/attempt.json`. This is a harness convention, not part of the design's prose.
- **Results are `result.json` from the smoke test only.** The booted side never writes
  `attempt.json`. The evaluator compares the booted KVER and image digest with the
  attempt record; a run that cannot prove which artifact it booted is `HARNESS_ERROR`,
  because it cannot support a model claim.
- **The smoke test asserts the named set, never a count.** `t2gmux` on a 13-inch model is
  the one object that must be *absent*; that is an assertion, not a skip.
- **`modules` asserts loaded, not bound.** `/sys/module/<name>` proves the object loaded.
  Driver-to-device binding depth is not asserted; `hid_t2magicmouse` is expected loaded
  and unbound.
- **A failed smoke verdict exits the unit 0.** The verdict lives in `result.json`; a
  failed unit would pollute the `systemctl --failed` assertion the test just made.
- **No suspend cycle.** See §6. This is the largest known gap against design §9's smoke
  list, and it is stated rather than papered over.
