# Artifact 2 bench slice — Tier 0 evidence (2026-10-20 snapshot)

Preserved 2026-10-21 from `.work/bench-image/EVIDENCE.md` before the scratch tree was
deleted. The content below this line is verbatim.

**Read the image ids as the 2026-10-20 build's.** Later rebuilds changed the id while these
ten gates and the lint result stayed the same; gates 11–16 (T7 units; report and models.d; the apps; SELinux/PAM; docs; hub) were added 2026-10-21
and the current image ids are recorded in `research/findings/module-pipeline.md` §9. The
Tier 2 run records are in [`docs/runbooks/tier2-bench.md`](../runbooks/tier2-bench.md)
§0a–§0c. The gates themselves are owned by `build_files/90-tests.sh` and the step order by
`Containerfile`.

---

# EVIDENCE — Artifact 2 bench slice, built and gated (Tier 0 only)

Design of record §5 (Artifact 2) and §14 (T4/T5/T6/T12), cut down to the **boot path**
only. Nothing here has been booted; no disk has been written. The Tier 2 run is the next
step and it is human-gated.

| | |
|---|---|
| Image | `localhost/bluefin-t2-bench:7.2.5-200.fc44.x86_64` |
| Image id | `f48ae4b920fccc7a50067aae3a1db7fe32e2fd9e1dc46ea1ecf052ec706ff4df` |
| Image digest | `sha256:b182e934b3366383f5770dc913f03ec2ed49b4ae75a734efce4f25cc6cf7657e` |
| Base | `ghcr.io/ublue-os/bluefin@sha256:23b7bf54349f1a93c2fea4168c7725a632641ee67ae29b0951ef1976c1ba2bc9` (Bluefin 44.20261013) |
| Target kernel | `7.2.5-200.fc44.x86_64`, read from that digest's `ostree.linux` label |
| kmods | 12 RPMs from A1, each `Requires: kernel-core-uname-r = 7.2.5-200.fc44.x86_64` |
| Image size | 7.84 GB (base is ~7.7 GB; the delta is the 18 modules, the initramfs and the harness layer) |
| **Tier reached** | **Tier 0** — the image is internally correct for the target release. Not booted. |

## What the gates proved (all ten, in the finished image)

```
== 1. kernel identity ==            ok: exactly one kernel tree: 7.2.5-200.fc44.x86_64
== 2. the 18 objects, by name ==    ok: 18/18 objects present; no unexpected t2 object
== 3. vermagic ==                   ok: all 18 carry vermagic 7.2.5-200.fc44.x86_64
== 4. signed ==                     ok: all 18 signed, PKCS#7
== 5. depmod ==                     ok: all 18 objects in modules.dep; depmod clean
== 6. initramfs (lsinitrd) ==       ok: carries all six early-boot objects
== 7. kargs ==                      ok: 13 kargs, exact and diffable
== 8. no build residue ==           ok: no kernel-devel, no /usr/src tree, no staging dir
== 9. force_drivers ==              ok: equals the six early-boot objects
== 10. harness layer ==             ok: units, stage loggers, smoke test and models.d present
ALL TIER 0 GATES PASSED for 7.2.5-200.fc44.x86_64
```

`bootc container lint`: **14 checks passed, 1 skipped, 0 warnings, exit 0.**

## The artifacts inside the image

- **18 objects** in `/lib/modules/7.2.5-200.fc44.x86_64/extra/`, every one signed with the
  throwaway proof key (not production, not enrolled in MOK).
- **Initramfs** 253,014,735 B rebuilt with `--no-hostonly --reproducible --add ostree`, and
  it carries `t2bce_dma t2bce_core t2bce_vhci t2hid t2smc t2sbs` by name. That naming is
  the proof: dracut only warns on a missing forced driver.
- **13 kargs** at `/usr/lib/bootc/kargs.d/00-t2.toml`, asserted by array equality, not by
  count. `module_blacklist` is what stops the stock Apple drivers binding first.
- **`models.d/MacBookPro16,2.toml`** — 16 expected_loaded, `hid_t2magicmouse`
  expected_unbound, `t2gmux` expected_absent, matching both design §4 and the live host.
- **Harness layer** (bench-only): two stage loggers, the smoke test, three units with their
  `.wants` symlinks and a preset.

## Deliberately excluded from this slice

The release surface, because none of it is needed to answer "does it boot with the modules
bound": the eight apps, the hub, `bluefin-t2 report`, Touch ID provisioning, PAM
fingerprint, the SELinux module, the firmware import path, and the ISO/kit (Tier 3).
`docs/runbooks/tier2-bench.md` §2 and §6 name what that costs this run.

## What this does NOT prove

1. **That the image boots.** No install, no boot, no hardware. That is Tier 2.
2. **Wi-Fi.** The Apple firmware for this machine's BCM4364 is *not* in the image — it is
   owned by no package on the host, i.e. placed by hand from macOS, exactly as the design
   requires. Until those four files are copied to the target's
   `/var/lib/firmware/brcm/`, the booted image has no Wi-Fi and the smoke test's Wi-Fi
   assertion will fail.
3. **Secure Boot acceptance.** The modules are signed with the throwaway key; this machine
   has Secure Boot disabled. Nothing here exercises MOK.
4. **Any model claim.** One recorded Tier 2 run on `MacBookPro16,2` would be required even
   to restate the existing claim for this artifact.

## Build corrections this produced

Recorded in `research/findings/module-pipeline.md` §5: the base image owns part of
`extra/` (zfs/spl/v4l2loopback) and ships a development toolchain, so "extra/ equals our
18" and "the build-only set is absent" are both wrong assertions for a derivative; and
`set -o pipefail` + `grep -q` reports failure on a match.
