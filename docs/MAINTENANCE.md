# What has to be maintained

This is the maintenance map for `bluefin-t2`: what decays, what triggers a rebuild, what a
release has to prove, and what is deliberately manual because the alternative is an overclaim.

## The dependency chain

```
Bluefin digest (ghcr.io/ublue-os/bluefin@sha256:…)
   └─ kernel 7.2.5-200.fc44.x86_64  (the digest's `ostree.linux` label)
        └─ akmods-t2: 12 modules × 18 objects, signed, RPM-locked to that kernel
             └─ bluefin-t2 image (release + bench slice)
                  └─ ISO (BIB, per release)  ──┐
                  └─ kit (macOS, versioned)   ─┴─ Tier 3
```

Nothing below the digest can be reused when the digest moves. That is the whole maintenance
burden: **a base bump is a kernel bump, and a kernel bump invalidates every module.**

## Triggers and the work each one forces

| Trigger | Work | Proof | Cadence |
|---|---|---|---|
| Bluefin `stable` digest moves | re-read `ostree.linux`; rebuild A1 for the new KVER; rebuild both images; new ISO | Tier 0 gates + `modinfo -F vermagic`; **Tier 2 scored run before it is offered** | per release, not per day |
| KAIT2EN submodule moves | re-pin the submodule, rebuild userspace (touchbar, touchid, dsp), re-run gates | Tier 0 + the affected subsystem's Tier 2 line | when upstream changes |
| Fedora package update in the base | nothing, unless it changes a gate's assumption (wireplumber, pipewire, NetworkManager, fprintd) | Tier 0; Tier 2 for pipewire/wireplumber/fprintd changes | as they land |
| Kernel bump only (no other base change) | A1 rebuild; the image rebuild is mechanical | Tier 0 `rpm -qpR` lock + signature; Tier 1 binds on the live host | per bump |
| Model claim (15,2 / 15,4 / 16,3) | a digest-pinned **Tier 2 run for that model** | the run's `result.json` | never batched |

## What is automated now

- `build.sh` pins the base digest, reads the kernel from that digest's label, and refuses kmods
  that are not `Requires: kernel-core-uname-r = <KVER>`.
- Eighteen Tier 0 gates run in the image build; `bootc container lint` runs last and is never
  skipped.
- `build.sh --release` strips the harness block; gate 10 asserts the release image has no HIL
  surface and the bench image has it.
- `dsp-select` picks the model's audio graph at boot from DMI; the gate proves install,
  idempotence, local-edit preservation and unsupported-model withdrawal.

## What is deliberately manual

- **A model claim.** No gate and no shared-code argument substitutes for a digest-pinned Tier 2
  run on that model. Until then the model is absent from the claimed set.
- **Publication and signing.** The throwaway proof key is not a product key. The DER in the image,
  the cosign key for the registry, and the MOK enrolment are a human decision; the rotation drill
  is run once per rotation, not per release.
- **The ISO.** Rebuilt per release from the release digest. It is never edited after the fact; a
  fix is a new ISO and a new Tier 3 run.
- **The kit.** Versioned with the image release it supports (`--version` prints it). macOS-only
  code cannot run in Linux CI; the `--check` path is the testable half and must be exercised on a
  real Mac before a release.
- **Firmware.** Never in the image. Captured per machine on macOS, carried by the kit, imported
  into `/var/lib/firmware` on first boot. There is no maintainable copy of it in this repository.

## The release checklist

1. `just -f akmods-t2/Justfile build` for the digest's KVER — all 12 specs, 18 objects, CMS
   signatures, `modinfo -F vermagic` matches.
2. `./build.sh` and `./build.sh --release` — 18 gates pass in both; lint clean.
3. Tier 2 scored run on the bench slice for the touched model; the release image is the same
   steps minus the harness, so the run's evidence covers it.
4. The interactive checks that only a person can do: Touch ID at login, Touch Bar, audio DSP
   filter chain, suspend/resume, hub.
5. ISO build + Tier 3 run if the installer surface changed; otherwise the previous ISO's provenance
   still names an older digest and must not be reused.
6. Document the digest, the image id, and what was and was not verified — the evidence page is the
   release note.

## Failure modes to expect

- **`invalid module format`** — the module was built for another kernel. Check the two versions
  before anything else.
- **Wi-Fi works during the install and not after** — the firmware did not cross, or the ESP copy
  failed its checksum. `journalctl -u bluefin-t2-firmware-import` and
  `/var/lib/bluefin-t2/firmware.state`.
- **Touch ID asks for a finger that is not enrolled** — the T2 was power-cycled; boot macOS once
  and log in. Rebooting Linux does not re-arm the SEP.
- **No sound, but devices exist** — `dsp-select` did not install a graph (unsupported DMI, or a
  local `/etc/pipewire/pipewire.conf.d/51-t2-dsp.conf` it preserved): check
  `journalctl -u bluefin-t2-dsp`.
- **Touch Bar dead after a kernel bump** — the touchbar userspace is fine; the `t2hid`/`t2bce_*`
  modules failed to load. Never unload them to test.
