# Userspace layer — first slice: the builder stage and `bluefin-t2 report`

Date: 2026-10-21. Design §5 (A2 steps 02–05), §7 (report), §14 T4/T10. **Tier 0** — no boot,
no desktop session, no hardware claim.

**Result:** the builder stage exists and only `/out` crosses into the image; `bluefin-t2
report`, the eight confirmed class-A apps and `t2remote` ship as ten RPMs, with the report's
exit codes 0/1/2 proven on fixtures inside the build. The hub, SELinux and PAM are **not**
in this slice.

| | |
|---|---|
| Image | `localhost/bluefin-t2-bench:7.2.5-200.fc44.x86_64`, id `2681adfa…` |
| Digest | `sha256:f903b06f…` |
| User-space RPMs | 10: the report, the eight apps and `t2remote` |
| Gates | 16 (gates 12–16 are new); `bootc container lint` 14 passed / 1 skipped / 0 warnings |
| Base / kernel | `sha256:23b7bf54…` / `7.2.5-200.fc44.x86_64` |

## 1. The builder stage

`Containerfile` now has `FROM <pinned base> AS t2build`, then the image from the same digest:

* **B1** installs the build-only set (cargo, rust, gtk4/libadwaita/libinput/libplist/systemd/
  glib devel, rpm-build, pkgconf, gcc, make, checkpolicy, policycoreutils,
  selinux-policy-devel) — in the builder, never the image.
* **B2** copies the pinned KAIT2EN sources (`kait2en/`), `apps/`, `specs/`.
* **B3** runs `build_files/build-userspace.sh`, which cargo-builds each binary
  (`--release --offline --locked`), renders `specs/app-tree.spec.in`, and writes one RPM to
  `/out/rpms` plus a manifest.
* **B4** (the SELinux module) is reserved and not implemented.

Step 03 of the final image installs `/out/rpms/*.rpm` with `dnf5` and removes the dnf
residue in the same layer. `build.sh` stages `apps/`, `specs/` and the clone (without
`.git`) into the context.

Two failures found by building it, both a mode/packaging class rather than logic:

1. `RUN /usr/libexec/bluefin-t2/build-userspace.sh` exited **126**: the script was 0644.
   Any script a `RUN` invokes directly needs 0755; the same lesson as the polkit policy
   mode (a file's mode is part of its contract, not packaging detail).
2. A multi-line `%description` rendered through `sed` produced `unterminated 's' command`.
   The spec template is rendered with `sed`, so substituted values are single-line.

The builder-only set is now a gate assertion: gate 8 fails if `cargo`, `rust`,
`gtk4-devel`, `libadwaita-devel`, `libplist-devel` or `libinput-devel` is installed in the
final image. Those are absent from the Bluefin base, so their presence would mean the build
tree itself crossed the stage boundary, not just `/out`.

## 2. `bluefin-t2 report` — the contract

`apps/bluefin-t2/` is our Rust crate (no external crates; `--offline --locked` is therefore
honest, not a workaround). Binary `/usr/bin/bluefin-t2`, subcommand `report`; no arguments
is still usage, not the hub (T11).

* exit **0** — supported model, every required check passes
* exit **1** — supported model, something required is missing or failed
* exit **2** — the model is not in the supported set (soft verdict, never a refusal)

Checks in v1: model file and evidence tier, kernel, image, Secure Boot (`mokutil`; **off is
allowed**, on-with-key-not-enrolled fails), the three module categories against `/sys/module`,
firmware state, failed units. Output modes: human, `--markdown` (the bug-report body), and
`--json` — the schema is `docs/report-schema.md`, and it is the contract shared by the CLI,
the hub and the Tier 2 smoke test.

`--root DIR` reads facts under a fixture tree and executes no runtime command. That is how
Tier 0 drives the exit codes without a T2 machine or a boot:

```
ok: models.d: 4 files, 18 objects each, measured split only on 16,2
ok: report: exit 0 / 1 / 2 on fixtures, JSON and markdown contract intact
```

A caveat that is not a defect: a container shares the host's kernel, DMI and `/sys/module`,
so `report` run *inside a container* describes the host, not the image. It is meaningful on
the booted system, and on fixtures via `--root`.

## 3. `models.d` is four files

`MacBookPro16,2` is `validated` with the measured split (`hid_t2magicmouse` unbound,
`t2gmux` absent). `15,2` and `15,4` are `validation-set`, `16,3` is `argument`; on those
three, the two measured states are moved to `unmeasured` and the report prints `untested`,
never `working` (design §12 Q3, §4). Gate 12 parses all four with `python3 tomllib` and
asserts that each names the 18 objects exactly once across the four arrays, that only 16,2
carries the measured split, and that no other file claims it.

## 4. The eight apps and t2remote

The confirmed class-A set (2026-10-21): `t2-touchbar`, `t2-fan-control`, `t2-smc-control`,
`t2-zone-power`, `t2-force-click`, `t2-debug`, `t2-power-explorer`, `t2-power-tune`, plus
`t2remote`; the report is the tenth package. Excluded as agreed: `t2-dgpu-control` and
`t2-hybrid-gpu-control` (class B, no dGPU on the four models), `t2-kernel-builder`
(contributor tool needing kernel sources) and `deprecated/`.

Packaging is explicit rather than `make install`: upstream's install targets call
`systemctl` and write as root, neither meaningful in a builder. Each app is staged into a
package tree and `specs/app-tree.spec.in` is rendered once per app; the `%files` list is
generated from the staged tree, with `/etc/**` marked `%config(noreplace)`. One shared
`CARGO_TARGET_DIR` across crates means the GTK stack compiles once, not six times.

Three derivative fixes, each because the upstream file assumes `/usr/local` or has a real
defect:

1. **Unit paths.** Every daemon unit hardcodes `/usr/local/bin/<binary>`. Staging renders
   `/usr/local/bin → /usr/bin` and `/usr/local/libexec → /usr/libexec` (t2remote's unit
   already uses `@BINDIR@` for the same reason).
2. **Desktop `Exec=` paths.** Six of the eight entries hardcode `/usr/local/bin/...`, which
   this image does not have. The staging renders them, and gate 13 resolves each entry's
   `Exec=` target to an executable — `desktop-file-validate` checks a file's shape, not
   that it launches anything.
3. **Self-ordering daemons.** The fan, SMC, zone-power and force-click units carry
   `After=multi-user.target` while being `WantedBy=multi-user.target`. A unit ordered after
   the target that wants it is an ordering cycle; systemd breaks such cycles by deleting a
   job. The line is dropped at staging, and gate 13 asserts it does not come back.

Enablement is declarative and deterministic: `81-bluefin-t2-apps.preset` (system and user)
plus the `/etc/systemd/**/*.wants` symlinks those lines name. The Touch Bar user daemon is
enabled globally, so the hub's documented escape hatch (`systemctl --global disable`) keeps
working.

Gate 13 asserts: the nine app RPMs are installed; ten binaries are executable; every
`org.t2*.desktop` passes `desktop-file-validate` **and** resolves its `Exec`; the six
system units verify, are enabled and do not self-order; the user unit is enabled; both
power-tool polkit policies are well-formed XML; the Touch Bar udev rule passes
`udevadm verify`. All ten binaries have a closed `ldd` (no "not found"), checked separately.

```
ok: 9 app RPMs: binaries, desktop entries, units, enablement, polkit actions and udev rule
ALL TIER 0 GATES PASSED for 7.2.5-200.fc44.x86_64
bootc container lint: 14 passed, 1 skipped, 0 warnings
```

Two lint residues were found and fixed at the source, not accepted: the gate's own
`systemd-analyze` markers in `/run` (cleanup moved to the very end of the gate script) and
`/var/cache/ldconfig/aux-cache`, recreated by the RPM scriptlets at step 03 (removed in the
same layer, as step 01 already did).

## 5. Step 04 and 05: SELinux, PAM, caches

The only policy source in the pinned tree is the Touch ID bridge's. B4 compiles it
(`checkmodule` + `semodule_package`, 2 521 bytes); step 04 installs it with
`semodule -X 400 -i`, so it sits ahead of the distribution's 100-level modules and replaces
none of them. `semodule -lfull` in the finished image:

```
400 kait2en-t2-touchid   pp
```

PAM fingerprint is `authselect enable-feature with-fingerprint` on the `local` profile.
Two corrections came out of doing it rather than describing it:

1. **The design's assertion was wrong.** §9 said `system-auth` *and* `password-auth` contain
   `pam_fprintd.so`. authselect writes the auth stack (`system-auth`) only; `password-auth`
   is the password-change stack and takes no fingerprint. The gate asserts what the tool
   produces, and the design carries the correction.
2. **authselect leaves `/var/lib/authselect/checksum`.** `bootc container lint` correctly
   flags non-directory content in `/var`; the checksum is boot-time state, and
   `authselect check` recomputes it and stays valid without it. Step 04 removes it in the
   same layer.

Step 05 runs `gtk-update-icon-cache`; no fonts are added by this image, so `fc-cache` is not
needed, and no dconf profiles are shipped, so `dconf update` is not needed either. The
build-step scripts (`01-install-kmods.sh`, `19-initramfs.sh`, `90-tests.sh`) are removed at
the end of step 07: they are build-time harness, and leaving them was exactly the residue
gate 8 and gate 14 exist to prevent. Gate 14's first version found its own script because it
searches for the words it contains; the scan now covers the runtime helpers and unit files
only, which is the property that matters.

Gate 14 asserts: the module at priority 400, `pam_fprintd.so` on the auth stack,
`authselect current` listing with-fingerprint, the icon-theme cache, and that no runtime
unit/helper invokes `semodule`, `semodule_package`, `grubby` or `dkms`.

## 6. The hub (T11)

`bluefin-t2` with no arguments opens the hub; `bluefin-t2 report` stays the verdict, and
`report` never initialises GTK, so a headless rescue session can still run it. The hub reads
`report --json` and nothing else: it runs the report as a child process and renders the
documented contract. Pages whose subject is not in the contract (Performance, Display,
Network, Users) say so and name the component that owns the state — they do not invent a
status. Nine pages, 26 rows on this machine.

`--check-gui` builds the same page model with no display and no GTK initialisation. Gate 16
proves: nine named pages each with rows; an exit-2 (unsupported model) document is accepted,
because a soft verdict is not a contract failure; the binary links `libgtk-4.so`; and the
desktop entry validates and execs a real binary. The window, its layout and its interaction
are Tier 2/3 — no gate here claims otherwise.

Adding GTK is a dependency the crate did not have, and it is justified: the hub is the
design's `bluefin-t2` binary and a second binary would contradict §5/§7. The cost is stated:
the report crate's build now needs the registry (no more `--offline`), pinned by
`--locked`; `Cargo.lock` grew from 1 package to 79.

## 7. What is still not in this slice

Nothing from the design's userspace layer is missing at Tier 0. The hub's window, the
desktop session, the daemons talking to hardware and the Touch Bar attaching are all Tier
2/3. Next: A1 publication (T3, human gate), the real Artifact 2 and a release Tier 2 on this
16,2, then the Tier 3 kit.
