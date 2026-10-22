# Module pipeline — T1 proof findings

Date: 2026-10-20. Design of record §15 (T1, `docs/designs/kait2en-bluefin-v2.md:1299`).
Session evidence: `.work/host-7.2.11/EVIDENCE.md`, `.work/image-7.2.5/EVIDENCE.md`
(scratch, not durable — this file is the record).

**Result: both halves pass.** `t2smc` builds, signs and binds against the host kernel; it
builds and signs against the image kernel without loading. T1 is green, and one of the 18
objects is now proven against the per-release kernel.

| | Host half | Image half |
|---|---|---|
| Kernel | `7.2.11-200.fc44.x86_64` (`uname -r`) | `7.2.5-200.fc44.x86_64` (label on digest `sha256:23b7bf54…`) |
| Tier | 1 (loaded, bound, rolled back) | 0 (never loaded) |
| `vermagic` | matches | matches |
| Signature | CMS verifies; negative controls reject | same |
| `rpm -qpR` | — | `kernel-core-uname-r = 7.2.5-200.fc44.x86_64` |
| `depmod` | n/a | clean; `modules.dep` lists `extra/t2smc.ko` |

## 1. The operational finding: an aged-out kernel is not rebuildable from the repos

`kernel-devel-7.2.5-200.fc44` is **gone from the Fedora 44 repositories**. `updates` carries
only `7.2.11-200`; `fedora` carries `6.19.10-300`. The 7.2.5 kernel packages survive only on
Fedora's build system:

```
$ dnf5 repoquery --available kernel-devel
kernel-devel-0:6.19.10-300.fc44.x86_64
kernel-devel-0:7.2.11-200.fc44.x86_64
$ curl -sI https://kojipkgs.fedoraproject.org/packages/kernel/7.2.5/200.fc44/x86_64/kernel-devel-7.2.5-200.fc44.x86_64.rpm
HTTP/1.1 200 OK
```

**Those koji artifacts carry no GPG signature** — `RSAHEADER=(none)`, `SIGPGP=(none)`,
`rpm -K` verifies payload digests only. So anything built for a `KVER` after it leaves
`updates` rests its provenance on HTTPS to koji and a header field, not on a verified Fedora
signature.

### What this forces

1. **A1 must build while the release is current.** The clean path is a `kernel-devel` from a
   signed repository, which exists only while that kernel is the current one. This makes the
   ordering in R2-13 load-bearing rather than stylistic: it is not merely "publish promptly",
   it is "after a week or two the clean provenance path is gone".
2. **The immutable `<flavor>-<fedora>-<KVER>` tag is load-bearing too.** It is the only clean
   way to reuse a kmod after the source kernel has aged out — you cannot regenerate it.
3. **A late rebuild needs a pinned hash, not a skipped check.** If one is ever required, record
   the `sha256sum` of each kernel-devel/kernel-core RPM in the run and pin it, rather than
   trusting a floating tag. Weakening the signature check to make a late build pass is the
   failure the project's own rules forbid.

## 2. The CMS verification nuance (it costs an afternoon if unknown)

A module signature covers the module bytes **before** the appended signature block
(`sign-file.c` signs the module file; the kernel's `mod_verify_sig()` subtracts sig +
descriptor + magic). So the obvious check fails on a *correct* signature:

```console
$ openssl cms -verify -inform DER -in sig.der -content t2smc-signed.ko -certfile key.pem -noverify
CMS Verification failure ... rsa_verify:bad signature ...   [exit 4]
```

The correct content is the pre-signature module (the unsigned build output, or
`extract-module-sig.pl -0 <signed.ko>`). Extract the signature with `-s`, keep **stdout
binary and stderr separate** (merging them corrupts the DER), and prove the check is not
vacuous with a byte-flip negative control.

Also: `sign-file` uses `CMS_NOCERTS`, so the CMS embeds **no certificate**. Identity is
established by `sig_key` equalling the certificate serial plus supplying the certificate to
`-certfile`; an unrelated certificate fails at signer lookup.

## 3. What T1 does and does not prove

Proven: the sources compile unmodified against both releases; signing works; the signature
verifies; the module binds a real T2 kernel (`t2smc APP0001:00: initialized: keys=1078 fans=2
temps=36 …`), creates its hwmon node, and `sensors` reads 2 fans and 36 temperature channels;
`rpm -qpR` carries the kernel lock; `depmod` is clean.

Not proven: the kernel **accepting** the signature (Secure Boot is off here — the module
loaded with taint `OE`, `TAINT_UNSIGNED_MODULE`, so no MOK path was exercised); the other 17
objects; the initramfs guarantee; anything about the image, boot, suspend or fan control.

Two smaller observations:

- The research clone is at module version `0.0.4`; the machine's DKMS build is `0.0.3`. The
  proof exercised the newer code.
- `modinfo <name>` reads the on-disk module index, not the loaded instance, so it reports the
  DKMS build even after `insmod` of a different copy. The loaded instance is identified by
  `/sys/module/<name>/srcversion` and the kernel log.

## 4. Consequences for the next tasks

- **T2** (remaining 11 specs / 17 objects) is the open question in §12 Q1, and it is the next
  work — not a scheduling question.
- **A2 step 01** should record the kmod source (registry digest or, for a bench slice, the
  `sha256sum` of every RPM it installs) in the build output, so a bench image is tied to
  artifacts rather than to a directory that may change underneath it.
- The bench slice may stub the kver tag (§14 permits it: "a stub works until then"), but it
  must not stub the `rpm -qpR` assertion — that is the property the tag check exists to guard.

## 5. Corrections found while building the Artifact 2 bench slice

Building the bench image (Tier 0 through `bootc container lint`) corrected three
assumptions. Each one failed a build first; none was a fault in the modules.

1. **`/lib/modules/<kver>/extra/` is not ours alone.** The Bluefin base already ships its
   own akmods there — `zfs`, `spl`, `v4l2loopback`. An assertion of the form "the set in
   `extra/` equals our 18" therefore fails on a *correct* derivative. The safe form is:
   each of our 18 present exactly once, and **no object matching `^(hid_)?t2` outside the
   named set**. That still catches a stale or renamed module, and does not punish the base
   for being the base.
2. **"The build-only set is absent" (design §9) is false for a Bluefin derivative.**
   `gcc`, `gcc-c++`, `make`, `checkpolicy` and `kernel-headers` (which owns
   `/usr/include/linux/version.h`) are in the base image. The property that actually
   matters — and that a derivative controls — is that **`kernel-devel` and `/usr/src`**
   are absent, because those are what would let the image compile or carry a module for
   the wrong kernel. §9 should say "the build-only set the builder stage installs", not
   "the build-only set".
3. **`set -o pipefail` plus `grep -q` is a false-negative generator.** `lsinitrd … |
   grep -q <name>` reports failure when the name *is* present: `grep` exits 0 on the first
   match, the writer takes SIGPIPE, and the pipeline returns 141. The gate read that as
   "missing" and failed a correct initramfs. Grep a file (or use a here-string); never
   pipeline into `grep -q` under `pipefail`. The same shape appeared twice in the gate
   script and both instances were fixed.

Two smaller operational notes:

- **dracut in a container prints `[E]` and exits 0.** `dracut[E]: No '/dev/log' …` and
  `dracut-install: ERROR: installing '/root'` appear on every run, and the initramfs is
  still produced correctly. Exit status alone is therefore not proof of the initramfs
  guarantee — the `lsinitrd` name assertion is, exactly as the design says.
- **The bench slice must carry the harness layer and `models.d`.** Without
  `COPY harness/rootfs/ /` a boot writes no stage lines and no `result.json`, and the run
  correctly reports `FAILED_BOOT`/`HARNESS_ERROR`. Without
  `/usr/share/bluefin-t2/models.d/<ProductName>.toml` the smoke test fails with
  `models.d-missing` — by design, because the image is then incomplete.

## 6. The firmware assertion in §9 is too narrow to fail

Design §9 Tier 2 says the smoke test asserts "no `firmware load failed` in `dmesg`". That
literal string is not what the Wi-Fi driver on this hardware emits. brcmfmac reports:

```
brcmfmac 0000:01:00.0: Direct firmware load for brcm/brcmfmac4364b3-pcie.apple,trinidad-….bin failed with error -2
```

So a literal grep passes while the radio has no firmware at all. Observed on 2026-10-21,
run `20261020T164431Z-235e`: `/var/lib/firmware` was absent on the target, the Wi-Fi
assertion correctly failed with `not-associated-after-60s`, and the firmware assertion
still scored **ok** — a vacuous assertion, the same class of defect as a count assertion.

The harness now matches the family (`Direct firmware load for … failed`, `firmware load
failed`, `failed to load firmware`, `Falling back to sysfs fallback for`) **and** requires
that the driver actually created a `phy80211` interface, which is the thing a missing
firmware prevents. §9's wording should be corrected to name the pattern rather than the
phrase.

Related and worth stating: **a reinstall wipes `/var`**, so the per-machine firmware copy
must be repeated for every bench cycle. That is not a defect — it is exactly why the
firmware is per-machine and not in the image — but it is a step an operator will skip, as
happened here.

## 7. Wi-Fi on the bench image: the request name differs from the working host

On the working host (kernel `7.2.11`) brcmfmac selects a **board-qualified** firmware
name:

```
brcmf_fw_alloc_request: using brcm/brcmfmac4364b3-pcie for chip BCM4364/4
brcmf_c_process_txcap_blob: TxCap blob found, loading
```

and the files on disk are `brcmfmac4364b3-pcie.apple,trinidad-HRPN-u-7.7-X3.bin`,
`…apple,trinidad-X3.clm_blob`, `…apple,trinidad-X3.txcap_blob`.

On the bench image (**kernel `7.2.5`**) the driver asks for the **unqualified** base name
and fails when it is absent:

```
brcmfmac 0000:e5:00.0: Direct firmware load for brcm/brcmfmac4364b3-pcie.bin failed with error -2
```

No board-qualified attempt appears in the log, and the interface list is empty. Both
kernels' `brcmfmac` contain the same `board_type`/`dmi_board_type` symbols and the same
`apple,%s` format string, so the board type is not being resolved on 7.2.5 by whatever
mechanism resolves it on 7.2.11. **Root cause is unknown**; it is a kernel-side question,
not an image or firmware one, and it is recorded here rather than papered over.

What is known to work around it, and what KAIT2EN's own scripts do: install the same
firmware under **both** the board-qualified and the generic base name
(`research/KaiT2en-Fedora/scripts/fedora/deprecated/brcm_fw.sh:302` has an explicit branch
for `brcmfmac*-pcie.bin`). For the bench, that means placing in the target's
`/var/lib/firmware/brcm/`:

```
brcmfmac4364b3-pcie.bin              <- the trinidad …-X3.bin
brcmfmac4364b3-pcie.clm_blob         <- …apple,trinidad-X3.clm_blob
brcmfmac4364b3-pcie.txcap_blob       <- …apple,trinidad-X3.txcap_blob
brcmfmac4364b3-pcie.txt              <- …apple,trinidad-HRPN-u-7.7.txt
```

This is per-machine firmware placement, not image content, so it does not violate the
firmware rule. **It is a workaround, and it must be stated as one**: if the release image's
kernel resolves board types the way the host does, the qualified names are what the kit
should install, and the generic copies are harmless duplicates.

A separate, mundane failure on the same run: the firmware copy silently landed nowhere.
`/run/media/matt/root` is the target btrfs mount, and `ostree/deploy/default/var` is the
persistent `/var`; a copy made while that mount is absent writes into a plain directory on
the host instead. **Always verify the mount and the destination after copying** — the boot
log is too late to find out.

**Decision (2026-10-21, human): the firmware channel installs BOTH name forms.** The kit's
firmware payload will carry the board-qualified files *and* the generic base names, because
the bench kernel asks for the generic name and the qualified-only layout was proven
insufficient on `7.2.5`. This is a payload decision, not a change to the channel: firmware
still comes from the running macOS, still lands in `/var/lib/firmware/brcm`, and still never
enters the image. The board-type question stays open as a kernel investigation; if it is
answered, the generic copies become harmless duplicates rather than load-bearing.

**Confirmed 2026-10-21:** with both name forms in place the radio associates. On the same
installed image that had failed with `Direct firmware load … failed with error -2`, Wi-Fi
connected and Bluetooth paired a trackpad. The generic-name copies are therefore sufficient
for kernel `7.2.5` on this hardware, and the qualified names are harmless alongside them.
What remains unknown is *why* 7.2.5 resolves no board type — a kernel question, not a
firmware one, and the release must answer it rather than inherit the workaround silently.

## 8. A1 promoted out of scratch, and the initramfs gate's negative control (2026-10-21)

Task 0 and T5 of the session brief. Both are Tier 0: no module loaded, no boot.

### 8.1 The A1 recipe now lives in `akmods-t2/`

`.work/a1-kmods/` and `.work/image-7.2.5/` held the only copy of the build recipe, and of the
four 7.2.5 kernel RPMs (no longer in the Fedora repositories — §1). The recipe moved to
`akmods-t2/`, the kernel RPMs moved to `akmods-t2/container/rpms/` and are hash-pinned in
`container/kernel-rpms.sha256`, and `.work/` is deleted. No key material was promoted:
`certs/` holds only the public certificate of the throwaway proof key.

Verified, not assumed:

| Check | Command | Result |
|---|---|---|
| sources at the pin | `akmods-t2/scripts/stage-sources.sh` | clone HEAD `ba9d2d83…`; 17/17 directories byte-identical; recorded `tree_sha256` reproduced under `en_US.UTF-8` |
| recorded artifacts | `verify-artifacts.sh akmods-t2/out/rpms 7.2.5-200.fc44.x86_64 certs/t2-proof-THROWAWAY.pem --exact` | 12/12 RPMs, exact `kernel-core-uname-r`, 18/18 objects, vermagic/signer/PKCS#7/CMS, content and signed-byte records, byte-flip control rejected |
| the recipe still builds | `run.sh --digest 23b7bf54… --out /var/tmp/…` | `RESULT: 12/12 specs built, 18/18 modules signed, 12/12 RPMs`; the pre-signature content of all 18 reproduced against `record/modules.content.sha256` with a **new** throwaway key |

`record/modules.content.sha256` is new: pre-signature content is key-independent, so it is
what a rebuild is compared against when the signing key differs. `record/modules.sha256`
still pins the canonical signed bytes.

Two defects were found by the move and fixed in `run.sh`: podman reads a relative bind-mount
source as a **named volume** (mount sources must be absolute), and `grep … | tail` under
`pipefail` aborted the orchestrator on a failed build before it could report or record it —
the §5.3 trap in another shape.

### 8.2 T5 — the `lsinitrd` gate fails when it should

One `force_drivers` entry was broken (`t2bce_dma` → `t2bce_dmax`) in
`system_files/usr/lib/dracut/dracut.conf.d/90-t2-input.conf` and the bench slice rebuilt,
pinned to the same base digest:

```
dracut-install: Failed to find module 't2bce_dmax'
...
== 6. the initramfs guarantee — by name, via lsinitrd ==
GATE FAIL: initramfs is missing t2hid.ko — dracut only warns, so this assertion is the proof
[build exit 1]
```

The gate fired at step 6, before gate 9's set comparison — the property the design names. The
named object is `t2hid`, not the typo'd one: the failed force-install dropped the whole forced
set, and `t2hid` is the first object with no other reason to be in the initramfs (the BCE
components resolve as dependencies of each other).

Restored (`sha256 b0c6673d…`, identical to before) and rebuilt with `--no-cache`, so dracut
and the gates really re-ran:

```
ALL TIER 0 GATES PASSED for 7.2.5-200.fc44.x86_64
image id abac7215…, digest sha256:cce62b17…
bootc container lint: Checks passed: 14 / skipped: 1, exit 0
```

The previously recorded bench image (`91ae4445…`, digest `eddfa517…`) remains in podman
storage; the tag now points at the fresh no-cache build of the same tree content. Neither is a
Tier 2 run and neither supports a model claim.

## 9. T7 — the T2 units, with the conditions fixed (2026-10-21)

Tier 0. The four units we author, one privileged helper, the polkit action, the device group,
and gate 11 plus its negative controls. No boot, no user session, no hardware.

### 9.1 What shipped

| Path | Role |
|---|---|
| `system_files/usr/lib/systemd/user/bluefin-t2-first-login.service` | per-user provisioning; `ConditionPathExists=!%h/.config/bluefin-t2/provisioned`, `ConditionUser=!@system`, `ExecStart=/usr/bin/pkexec …/provision-user` |
| `system_files/usr/libexec/bluefin-t2/provision-user` | no positional argument; derives the account from `PKEXEC_UID`; binds Touch ID config, adds the group, writes the marker as the caller |
| `system_files/usr/share/polkit-1/actions/org.bluefin_t2.provision-user.policy` | `allow_active=yes`, `allow_any=no`, `allow_inactive=no`, `exec.path` pinned |
| `system_files/usr/lib/systemd/system/bluefin-t2-firmware-import.service` | conditioned on `/boot/efi/kait2en/firmware/wifi/SHA256SUMS` |
| `system_files/usr/lib/systemd/system/bluefin-t2-firmware-import.path` | `PathExists=` on the same marker; writes only under `/var` |
| `system_files/usr/libexec/bluefin-t2/firmware-import` | verify, space check, copy to `/var/lib/firmware/brcm`, verify destination, state in `/var/lib/bluefin-t2`, `brcmfmac` reload |
| `system_files/usr/lib/systemd/system/bluefin-t2-nm-bridge.service` + helper | idempotent Apple T2 Bridge profile for the CDC-NCM link |
| `system_files/usr/lib/sysusers.d/80-bluefin-t2.conf` | `kait2en-touchbar` group, materialised by `systemd-sysusers` in the build |
| presets + `/etc/systemd/**.wants` symlinks | declarative enablement and the deterministic links it names |

The eleven inherited units are **not** shipped here: they belong to the upstream packages
(T4 step 03). Gate 11 asserts the named four and must extend its set when those packages land.

### 9.2 Four defects found while implementing

1. **The design's R2-9 snippet puts conditions in `[Service]`.** systemd says
   `Unknown key 'ConditionPathExists' in section [Service], ignoring` (and the same for
   `ConditionUser`), so the conditions are silently disabled — which restores exactly the
   defect R2-9 exists to fix. They are `[Unit]` keys; the shipped unit has them there.
   **The design's code block is wrong and should be amended.**
2. **`pkaction` ignores a policy file it does not consider readable.** The repo's
   `system_files` files had been created 0600; the image built, and the action simply did
   not exist. Files are now 0644 and helpers 0755, and gate 11 asserts the modes.
3. **The gate left build residue.** `systemd-analyze verify` creates
   `/run/systemd/{ask-password,systemd-units-load}`, and the private polkit authority
   creates `/run/dbus` and `/var/lib/polkit-1`; `bootc container lint` correctly reported
   `nonempty-run-tmp` and `var-tmpfiles` (12 passed / 2 warnings). Gate 11 removes only
   those paths; lint is back to 14 passed / 0 warnings.
4. **`kait2en-touchbar-attach.service` does not match its description in §6.** The design
   says it conditions on the t2bdrm DRM node; the live unit (and the clone's) conditions on
   the user unit being globally enabled (`ExecCondition=systemctl --global is-enabled`).
   There is no DRM-node condition. Left as written; the design's description is stale.

`systemd-analyze verify` also prints an unrelated base-image ordering-cycle warning
(`app.slice` / `systemd-oomd`) with exit 0. It is not ours; do not chase it.

### 9.3 Gate 11, and the eight controls that prove it fails

Gate 11 asserts: the named set of four; `systemd-analyze verify` for each; the exact
condition keys; `ExecStart` with no argument; the helper refuses an argument (exit 2, by
name) and a missing `PKEXEC_UID`; policy XML values and `pkaction --verbose`
(`implicit active: yes`, `implicit any: no`, `exec.path`); the `SHA256SUMS` condition and
`PathExists`; no `/var/lib` path in the `.path` unit; presets and symlinks; `getent group`;
helper modes and `bash -n`. `pkaction` needs a polkit authority, which a build container
does not have, so the gate starts a private system bus plus `polkitd`, asserts, and removes
what it created.

Each defect was reintroduced and the gate run against it:

| Defect reintroduced | Gate output |
|---|---|
| `ConditionPathExists=` de-inverted | `GATE FAIL: first-login must run while the marker is ABSENT …` |
| `ConditionUser` removed | `GATE FAIL: first-login must stay out of system/greeter sessions …` |
| helper argument guard disabled | `GATE FAIL: an argument must be refused as an argument, not for some later reason` |
| `allow_active=auth_admin` | `GATE FAIL: polkit action must be allow_active=yes …` |
| import conditioned on the directory | `GATE FAIL: import must be conditioned on the writer's SHA256SUMS marker` |
| `.path` also watching `/var/lib/firmware/brcm` | `GATE FAIL: the .path unit watches the service's own output …` |
| policy mode 0600 | `GATE FAIL: mode must be 0644: …` |
| one enable symlink removed | `GATE FAIL: missing enable symlink: …` |

### 9.4 Behaviour checked without hardware

`firmware-import` was run in a container against a synthetic payload (two files plus a
`SHA256SUMS`): it copied both files, wrote `firmware.state` with the payload hash and count,
and returned 0; a second run reported `already imported` and returned 0; a damaged
destination (one file deleted) was re-copied from the source; a corrupted source was
refused with `payload checksum verification failed … refusing to import it` (exit 1); and an
absent `SHA256SUMS` logged `nothing to import` and returned 0.

### 9.5 Result

```
ALL TIER 0 GATES PASSED for 7.2.5-200.fc44.x86_64
bootc container lint: Checks passed: 14, skipped: 1, warnings: 0
image id 28551880…, digest sha256:7dd07715…
```

Not proven: that a real first login provisions a real account, that a real payload imports
and the radio associates, that the bridge profile works, or that the units are ordered
correctly on the booted system. Those are Tier 2; the payload crossing is Tier 3. The bench
slice ships no desktop session, so the user unit is unexercised even by a bench run.
