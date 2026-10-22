# akmods-t2 — A1, the T2 kmod build

Artifact 1 of the design of record (`docs/designs/kait2en-bluefin-v2.md` §5): the 12 kmod
specs / 18 objects built, signed and packaged for the **exact kernel release of the pinned
Bluefin base digest** — `7.2.5-200.fc44.x86_64` for `sha256:23b7bf54…2bc9`.

**Tier reached: 0.** Built, signed, packaged and verified for the target release with no
module ever loaded. Tier 1 (binds on real hardware, safe set only) and Tier 2 (the image
boots) are the ladder above this. This directory is not a publication path; A1 publication —
immutable `<flavor>-<fedora>-<KVER>` tag, floating tag, cosign — is T3 and a human gate.

## What is here

| Path | What it is |
|---|---|
| `scripts/stage-sources.sh` | copies the pinned `research/KaiT2en-Fedora` tree into a build tree and proves byte identity (`diff -r`, plus the recorded `tree_sha256` values when a reproducing collation exists) |
| `scripts/build-all.sh` | runs **inside** the container: compiles 12 specs, signs and CMS-verifies every object, runs `depmod`, packages one RPM per spec, re-verifies inside the payload, and runs a byte-flip negative control |
| `scripts/run.sh` | host orchestrator: resolves `KVER` from the pinned digest's `ostree.linux` label, stages sources, builds the container if absent, runs the build, then verifies the RPMs from outside |
| `scripts/verify-artifacts.sh` | the assertion set on packaged artifacts only — no key, no `kernel-devel` for the target kernel needed |
| `scripts/fetch-kernel-rpms.sh` | fetches and hash-pins the four kernel RPMs (or `--check`s them) |
| `container/` | the proof container: `fedora:44` + the four 7.2.5 kernel packages + a toolchain |
| `container/kernel-rpms.sha256` | the pin: `<sha256>  <file>  <koji URL>` |
| `specs/kmod-t2.in` | the RPM spec template, rendered per module set — one packaging contract for the contributor `rpmbuild` loop and this proof build |
| `certs/` | the **public half** of the throwaway proof key, so the recorded RPMs can be verified |
| `record/` | the durable record: `KVER`, `MANIFEST.txt`, `modules.sha256` (signed bytes), `modules.content.sha256` (pre-signature content, key-independent), `STATUS.md`, `A1-EVIDENCE.md`, `SOURCES.md`, `evidence/build.log` |
| `out/` | generated: `rpms/` (12), `modules/` (18), `logs/`, `keys/` — ignored, never committed |

## Run it

```sh
just -f akmods-t2/Justfile throwaway-key   # proof key under out/keys/; read the warning
just -f akmods-t2/Justfile build           # stage + build + verify
just -f akmods-t2/Justfile verify          # assertions on out/rpms alone
```

Requirements: `podman`, `skopeo`, `jq` on the host; the four kernel RPMs either already in
`container/rpms/` or fetchable from koji; no sudo; nothing is written outside this
directory and `.build/`.

## The kernel comes from the digest, never from `uname -r`

`run.sh` reads `ostree.linux` off the pinned `ghcr.io/ublue-os/bluefin@<digest>`. The host
kernel is irrelevant: `vermagic` is part of a module's identity, and a module built for
`7.2.11` will not load under `7.2.5` — it fails with "invalid module format", not with a
symbol error. `--kver` exists as a deliberate override and warns for that reason.

## What the build asserts

* 12/12 specs built, **18/18 named objects** — never a count.
* Every object: `vermagic` first field equals the target release; signer CN equals the
  certificate's CN; `sig_id` is `PKCS#7`; extracted pre-signature content equals the
  unsigned build output; CMS verifies against the certificate.
* One byte flipped in an extracted payload must make the CMS fail — the check is not
  vacuous.
* `depmod -a "$KVER"` clean, every object in `modules.dep`, `modprobe --show-depends`
  resolves the BCE stack and `t2hid` without loading anything.
* Every RPM declares `Requires: kernel-core-uname-r = <KVER>` **exactly** — the structural
  lock that makes kernel/module mismatch an install-time failure even if a tag check were
  ever deleted (design §5; `build_files/01-install-kmods.sh` re-asserts it at image build).
* The packaged payload re-verifies after RPM packaging, and matches `record/modules.sha256`.

## Key policy

No key material is in this repository, and `just build` will not invent any. `certs/` holds
only the **public** certificate of the throwaway proof key that signed the recorded RPMs;
`out/keys/` is ignored. A production key is generated offline, used by CI only for
release-tagged builds, and its use is a human gate (design §5 and closed call 2). Rotation
is additive and overlapping: two `-signer` arguments in one CMS invocation for at least two
releases, which is exactly `dual-sign.sh`'s format in the pinned submodule.

## Provenance, and the one weak link

Sources are byte-identical copies of `research/KaiT2en-Fedora` at
`ba9d2d830ae5b4ccacf7f82ccc305270496397ff`; the pin and the per-directory hashes are in
`record/SOURCES.md`. The **kernel** RPMs are the weak link: `7.2.5` has aged out of the
Fedora 44 repositories, so `kernel-devel` comes from koji, where the artifacts carry no
Fedora GPG signature (`rpm -K` verifies payload digests only). Provenance for them is
HTTPS + the pinned sha256 in `container/kernel-rpms.sha256` — a pinned hash, never a
skipped check. That is design open question 5, and it is why A1 must build while the
release is current and why the immutable `<flavor>-<fedora>-<KVER>` tag is load-bearing
rather than cosmetic.

## What this does not prove

* Nothing here loads a module. Loading is Tier 1 (safe set: `t2smc`, `t2thunderbolt`,
  `t2mfi_fastcharge`, `t2smp`) or Tier 2.
* No initramfs, no image, no boot, no hardware. That is Artifact 2's build and the bench.
* No publication. T3 owns the tags, cosign and `KVER` resolution from ublue's akmods label.
* Secure Boot acceptance is unexercised: the throwaway key is enrolled nowhere, and the
  recorded Tier 2 runs had SB off.

## Promotion out of scratch — 2026-10-21

This directory replaced `.work/a1-kmods/` (scratch, deleted). The move was verified rather
than assumed:

* `stage-sources.sh`: clone HEAD `ba9d2d83…` matches the pin; 17/17 directories
  byte-identical; the recorded `tree_sha256` values reproduce under `en_US.UTF-8`.
* `verify-artifacts.sh` on the recorded RPMs: 12/12 RPMs, the exact `kernel-core-uname-r`
  line on all 12, 18/18 objects, vermagic/signer/PKCS#7/CMS on all 18, content hashes match
  `record/modules.content.sha256`, signed bytes match `record/modules.sha256`, and the
  byte-flip control is rejected.
* Full recipe re-run into a throwaway output directory with a **new** throwaway key:
  `RESULT: 12/12 specs built, 18/18 modules signed, 12/12 RPMs` and the pre-signature
  content of all 18 reproduced exactly against the record. That is what
  `modules.content.sha256` is for: a rebuild may use a different key, never different
  module bytes.

None of it proves loading, booting or publication. It proves the relocated recipe still
builds the recorded set for the recorded kernel.
