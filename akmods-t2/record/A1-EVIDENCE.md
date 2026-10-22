# EVIDENCE — A1: all 12 t2 kmod specs / 18 objects built, signed and packaged for 7.2.5-200.fc44.x86_64

Design §14 (T2), image-kernel half. **Proof build with a throwaway key.** Tier 0 only.

> **Relocated 2026-10-21**, verbatim, from `.work/a1-kmods/EVIDENCE.md` (scratch, since
> deleted) to `akmods-t2/record/`. One path below changed meaning: the build environment
> now lives at `akmods-t2/container/Containerfile`, not `../image-7.2.5/Containerfile`.
> `evidence/build.log` and `SOURCES.md` are beside this file, as they were.

| | |
|---|---|
| Target release | `7.2.5-200.fc44.x86_64` |
| KVER source | `ghcr.io/ublue-os/bluefin@sha256:23b7bf54349f1a93c2fea4168c7725a632641ee67ae29b0951ef1976c1ba2bc9`, label `ostree.linux` |
| Source | `research/KaiT2en-Fedora` @ `ba9d2d830ae5b4ccacf7f82ccc305270496397ff`, verbatim copies — see [SOURCES.md](SOURCES.md) |
| Signing key | `bluefin-t2 THROWAWAY proof key - NOT PRODUCTION` — enrolled nowhere, never production |
| Build env | `localhost/bluefin-t2-proof:7.2.5` (from `../image-7.2.5/Containerfile`): kernel-core/-modules-core/-modules/-devel 7.2.5 from koji, gcc 16.2.1, rpmbuild 6.0.2, OpenSSL 3.5.9, kmod 34.2 |
| Result | **12/12 specs built, 18/18 modules signed, 12/12 RPMs, container exit 0** |
| Transcript | [`evidence/build.log`](evidence/build.log) (524 lines) |
| **Tier reached** | **Tier 0** — internal correctness for the target release, asserted without touching the running kernel |

**No module was ever loaded.** `modinfo`, `extract-module-sig.pl`, `openssl`, `depmod` and
`modprobe --show-depends` only read files. (Podman shares the host kernel, so a load would
have hit the live machine — which is exactly why only non-loading commands were used.)

---

## 1. The two questions the design asked (§12 Q1)

### Q1 — which of the 18 objects fail to compile against 7.2.5?

**None. All 18 compile.** This is the answer, and it is a clean sweep rather than a
suppressed failure — here is the evidence it is not an artefact of a lenient build:

```console
$ grep -h 'error:' out/logs/*.build.log | wc -l
0
$ grep -hi 'undefined!\|unresolved' out/logs/*.build.log | wc -l
0
$ grep -h 'warning:' out/logs/*.build.log | sort | uniq -c
     12 warning: pahole version differs from the one used to build the kernel
```

The only warning is the benign BTF/pahole one (absent `vmlinux` in `kernel-devel`), emitted
once per spec; module BTF is skipped, which is normal for out-of-tree builds and does not
affect vermagic, loading or signing. Per-spec `make` exits are all 0, and the `CC [M]` line
counts show real work was done (a stack member is not a stub):

| Spec | RPM | Modules | `CC [M]` lines | make exit |
|---|---|---|---|---|
| `t2bce_stack` | `kmod-t2bce-stack-0.01-1` | t2bce_dma, t2bce_core, t2bce_vhci, t2bce_audio, t2bce_ave | 21 | 0 |
| `t2touchbar` | `kmod-t2touchbar-0.1-1` | t2hid, t2touchbar_bl, t2touchbar_kbd | 7 | 0 |
| `hid_t2magicmouse` | `kmod-hid-t2magicmouse-0.1-1` | hid_t2magicmouse | 3 | 0 |
| `t2bdrm` | `kmod-t2bdrm-0.1-1` | t2bdrm | 3 | 0 |
| `t2smc` | `kmod-t2smc-0.1-1` | t2smc | 3 | 0 |
| `t2sbs` | `kmod-t2sbs-0.1-1` | t2sbs | 3 | 0 |
| `t2mfi_fastcharge` | `kmod-t2mfi-fastcharge-0.1-1` | t2mfi_fastcharge | 3 | 0 |
| `t2gmux` | `kmod-t2gmux-0.8-1` | t2gmux | 3 | 0 |
| `t2thunderbolt` | `kmod-t2thunderbolt-0.6-1` | t2thunderbolt | 3 | 0 |
| `t2smp` | `kmod-t2smp-0.1-1` | t2smp | 3 | 0 |
| `t2_precision_trackpad` | `kmod-t2-precision-trackpad-0.01-1` | t2_precision_trackpad | 3 | 0 |
| `t2_trackpad_actuator` | `kmod-t2-trackpad-actuator-0.01-1` | t2_trackpad_actuator | 3 | 0 |

RPM versions come from each spec's own `dkms.conf` `PACKAGE_VERSION`, so `0.01`/`0.8`/`0.6`
are upstream's numbers, not invented ones.

### Q2 — did any module need a source patch?

**No patch was needed, and none was applied.** Every staged tree hashes identical to its
source before and after the build (`source_diff_failures=0`), the clone HEAD is unchanged,
and `research/` contains zero build products.

There is, however, a **layout requirement** that is easy to trip over and is not a patch —
it is how upstream stages the build, and getting it wrong produces a misleading failure:

> `t2bce_stack/Makefile` is five `obj-m += <dir>/` entries, so Kbuild expects
> `t2bce_dma/`, `t2bce_core/`, `t2bce_vhci/`, `t2bce_audio/` and `t2bce_ave/` **inside**
> `t2bce_stack/`. `t2bce_ave` does not even live under `modules/` — it is at
> `t2-services/t2-ave/kernel/t2bce_ave`.

`modules/t2bce_stack/README.md` says so ("They are staged below this directory by the Fedora
DKMS installer"), and `scripts/fedora/install-dkms-modules.sh` performs exactly that copy.
Built without staging, the error is a Kbuild complaint, not a compiler error:

```console
/usr/src/kernels/7.2.5-200.fc44.x86_64/scripts/Makefile.build:37: t2bce_dma/Makefile: No such file or directory
make[4]: *** No rule to make target 't2bce_dma/Makefile'.  Stop.
```

With the installer's layout reproduced (copy only), the single `make -C $KD M=… modules`
invocation builds all five objects and shares one symbol namespace, which is the point of the
stack spec:

```console
$ make -C /usr/src/kernels/7.2.5-200.fc44.x86_64 M=/work/build/t2bce_stack modules
  CC [M]  t2bce_dma/queue.o
  ...
  LD [M]  t2bce_ave/t2bce_ave.ko
[make exit 0]
```

`t2touchbar` is the other non-uniform Makefile (three `obj-m` modules, `t2hid` linking its
own object set, plus `-I$(srctree)/drivers/hid`); it needed no special staging — one
directory, three modules.

## 2. Environment

```console
container kernel (host kernel, shared): 7.2.11-200.fc44.x86_64
target KVER                          : 7.2.5-200.fc44.x86_64
fedora                               : Fedora release 44 (Forty Four)
kernel-devel                         : /usr/src/kernels/7.2.5-200.fc44.x86_64
gcc                                  : gcc (GCC) 16.2.1 20260819 (Red Hat 16.2.1-2)
rpm                                  : RPM version 6.0.2
openssl                              : OpenSSL 3.5.9 29 Sep 2026
modules in target tree: 4744
```

The kernel-devel tree self-identifies as the target release, and the koji packages used are
the ones recorded in task-1 (`kernel-core`, `kernel-modules-core`, `kernel-modules`,
`kernel-devel` — all `7.2.5-200.fc44.x86_64`, payload digests OK, unsigned koji builds).

## 3. The contract the image build consumes

| Path | Contents |
|---|---|
| `out/rpms/*.rpm` | 12 kmod RPMs, one per spec, each installing into `/usr/lib/modules/7.2.5-200.fc44.x86_64/extra/` |
| `out/MANIFEST.txt` | TSV: `rpm_file`, `sha256`, `modules` (comma-separated), `kver` |
| `out/modules/*.ko` | the 18 signed modules |
| `out/modules.sha256` | sha256 of each signed module |
| `out/STATUS.md` | per-spec status table |
| `out/logs/*` | per-spec build logs + per-RPM rpmbuild logs |
| `run.sh`, `scripts/build-all.sh` | reproducible driver (reuses the task-1 image) |

## 4. Verification 1/4 — vermagic, all 18

```console
$ modinfo -F vermagic out/modules/<each>.ko
7.2.5-200.fc44.x86_64 SMP preempt mod_unload
```

18/18, first field exactly `7.2.5-200.fc44.x86_64`, checked both in the container and again
on the host with kmod 34.2 (host check: `host_vermagic_or_signer_failures=0`).

## 5. Verification 2/4 — signer identity, all 18

Every module carries the same identity from the throwaway key:

```console
signer        bluefin-t2 THROWAWAY proof key - NOT PRODUCTION
sig_key       38:13:DE:F4:86:95:5F:14:D6:BA:F6:59:A9:A6:32:DC:7A:73:06:FB
sig_hashalgo  sha512
sig_id        PKCS#7
```

## 6. Verification 3/4 — CMS signature, all 18

Per module: extract the signature with `-s`, extract the signed content with `-0`, verify
with `openssl cms -verify -noverify` against the throwaway PEM, and confirm the extracted
content is byte-identical to the unsigned build output. The signature covers the module
**before** the appended signature block — verifying against the whole signed file fails by
construction, as established in task-1.

```console
PASS  t2smc: CMS signature verifies against the throwaway cert
...
```

**18/18 in the container** (OpenSSL 3.5.9), then **18/18 independently on the host**
(OpenSSL 4.0 + the host's `extract-module-sig.pl`):

```console
$ cat out/host-verify.txt
OK   hid_t2magicmouse         7.2.5-200.fc44.x86_64
OK   t2bce_audio              7.2.5-200.fc44.x86_64
OK   t2bce_ave                7.2.5-200.fc44.x86_64
OK   t2bce_core               7.2.5-200.fc44.x86_64
OK   t2bce_dma                7.2.5-200.fc44.x86_64
OK   t2bce_vhci               7.2.5-200.fc44.x86_64
OK   t2bdrm                   7.2.5-200.fc44.x86_64
OK   t2gmux                   7.2.5-200.fc44.x86_64
OK   t2hid                    7.2.5-200.fc44.x86_64
OK   t2mfi_fastcharge         7.2.5-200.fc44.x86_64
OK   t2_precision_trackpad    7.2.5-200.fc44.x86_64
OK   t2sbs                    7.2.5-200.fc44.x86_64
OK   t2smc                    7.2.5-200.fc44.x86_64
OK   t2smp                    7.2.5-200.fc44.x86_64
OK   t2thunderbolt            7.2.5-200.fc44.x86_64
OK   t2touchbar_bl            7.2.5-200.fc44.x86_64
OK   t2touchbar_kbd           7.2.5-200.fc44.x86_64
OK   t2_trackpad_actuator     7.2.5-200.fc44.x86_64
host verification: ok=18 bad=0
```

Negative control (so the CMS check is provably not vacuous): one flipped byte in the signed
content of `hid_t2magicmouse` was rejected —

```console
PASS  tampered content rejected (control on hid_t2magicmouse) — the CMS check is not vacuous
```

### The 18 modules

| Module | Bytes | sha256 (12) | vermagic | CMS |
|---|---|---|---|---|
| hid_t2magicmouse | 740 621 | `5f927276e531` | OK | OK |
| t2bce_audio | 1 512 509 | `24ddd3f7eeaa` | OK | OK |
| t2bce_ave | 1 709 237 | `9ba03a78b66f` | OK | OK |
| t2bce_core | 1 063 829 | `1dd74565df3f` | OK | OK |
| t2bce_dma | 561 653 | `11d453f4ed0e` | OK | OK |
| t2bce_vhci | 1 397 893 | `4c5fb98e7185` | OK | OK |
| t2bdrm | 640 917 | `5cb7463ca593` | OK | OK |
| t2gmux | 734 269 | `3c4f335d47cd` | OK | OK |
| t2hid | 686 605 | `72100e5c615f` | OK | OK |
| t2mfi_fastcharge | 429 669 | `093b5eb5405d` | OK | OK |
| t2_precision_trackpad | 642 693 | `cd746a4c8b68` | OK | OK |
| t2sbs | 458 541 | `468c983a9582` | OK | OK |
| t2smc | 1 053 933 | `c231e0821cd8` | OK | OK |
| t2smp | 464 237 | `0ce3b1b90510` | OK | OK |
| t2thunderbolt | 420 461 | `0bb5771354fe` | OK | OK |
| t2touchbar_bl | 532 997 | `d7095d7a394a` | OK | OK |
| t2touchbar_kbd | 592 613 | `15b5f9bd73dc` | OK | OK |
| t2_trackpad_actuator | 566 621 | `3dba2371b46a` | OK | OK |

Full hashes: `out/modules.sha256`.

## 7. Verification 4a/4 — depmod against the real 7.2.5 tree

All 18 were installed into `/lib/modules/7.2.5-200.fc44.x86_64/extra/` and depmod run there:

```console
installed 18 signed modules into /lib/modules/7.2.5-200.fc44.x86_64/extra/
$ depmod -a 7.2.5-200.fc44.x86_64
(no output)
[depmod exit 0]
PASS  depmod exit 0 with no warnings and no unresolved symbols
PASS  every module is present in modules.dep
```

`modprobe --show-depends` (resolves, does not load) shows the stack dependency order is
correct and that AVE's V4L2 dependencies resolve from the target tree:

```console
$ modprobe --show-depends -S 7.2.5-200.fc44.x86_64 t2bce_ave
    insmod .../extra/t2bce_dma.ko
    insmod .../extra/t2bce_core.ko
    insmod .../extra/t2bce_vhci.ko
    insmod .../extra/t2bce_ave.ko
    insmod .../kernel/drivers/media/v4l2-core/v4l2-mem2mem.ko.xz
```

and `t2bce_audio` pulls `soundcore`, `snd`, `snd-timer`, `snd-pcm` plus the stack. No
unresolved symbols means every symbol each module needs is exported by this exact kernel.

## 8. Verification 4b/4 — one kmod RPM per spec

Every RPM carries exactly one kernel dependency. The exact line, for `kmod-t2smc`:

```console
$ rpm -qpR out/rpms/kmod-t2smc-0.1-1.x86_64.rpm | grep kernel-core-uname-r
kernel-core-uname-r = 7.2.5-200.fc44.x86_64
```

All 12 RPMs were checked the same way and all report that identical line. Payload module
counts are 5 (`t2bce-stack`), 3 (`t2touchbar`) and 1 for the other ten, each under
`/usr/lib/modules/7.2.5-200.fc44.x86_64/extra/`.

Packaging does not damage the signatures: every module was extracted back out of its RPM and
re-verified (vermagic, signer, CMS) — 12/12 `PASS`.

> **This spec is a hand-written proof spec, not the final packaging mechanism.** It disables
> `__os_install_post` so rpmbuild's strip/BTF/debuginfo passes cannot invalidate the proof
> signature, and it expresses only the one dependency that matters here. A real kmod build
> needs a considered standalone answer for both.

## 9. What I could not verify

1. **That any module loads on the 7.2.5 image kernel.** No Tier 1, no Tier 2. The host runs
   7.2.11 and already carries DKMS builds of these modules; loading a 7.2.5-vermagic module
   there is impossible, and unloading the input modules on this laptop is forbidden.
2. **That a real kernel accepts these signatures.** The throwaway key is in no trusted
   keyring (and must never be enrolled). What is proven is CMS validity against that cert.
3. **Any behaviour at all** — fans, charge limit, Touch Bar, trackpad, Thunderbolt, audio,
   suspend. Nothing hardware-related was exercised.
4. **`hid_t2magicmouse`'s patched-kernel expectations.** KAIT2EN's docs describe this driver
   as needing "the required Asahi patches". It compiles against stock 7.2.5 headers and links
   cleanly, but that does not prove the runtime behaviour those patches provide; if the
   patch set targets kernel-side HID code rather than this module, the compiler cannot see it.
   Tier 2 is the only thing that can settle it.
5. **Equivalence with the image's actual module tree.** `depmod` ran against a tree built
   from kernel-core/-modules-core/-modules for 7.2.5. I did not diff it against the Bluefin
   image, nor check whether the image additionally ships `kernel-modules-extra`. Nothing
   needed was missing (depmod was silent), but that is argued, not measured on the image.
6. **The image's own toolchain** — built in stock `fedora:44`, not inside the Bluefin digest.
7. **BTF** — skipped for every module (no `vmlinux`), normal for out-of-tree builds.
8. **Packaging semantics beyond the requires line.** In particular `t2sbs` is documented as
   replacing the in-tree `sbs` driver; this proof RPM neither `Obsoletes` nor `Conflicts`
   with it, so both could be present at once. That is a real packaging decision still to
   make, not something the proof spec settles.
9. **RPM/koji provenance** — the koji kernel RPMs are unsigned build artifacts (payload
   digests only), and these kmod RPMs are unsigned too.
10. **A staging assumption worth naming:** the `t2bce_stack` build depends on the component
    directories being staged beneath it. The image build must reproduce that layout exactly;
    the script here does, but that is a property of my script, not of upstream's Makefile.

## 10. Audit trail of my own runs

The final `evidence/build.log` is run 3. Runs 1 and 2 failed because of defects in **my**
script, not in the modules — a stray `)` that bash rejected, then `for line in $SPECS`
word-splitting each module name into a phantom spec (6 "failures" appeared, and the
`kmod-t2touchbar` RPM would have contained only `t2hid.ko`). Both were fixed before the
reported run, and the reported run's `kmod-t2touchbar` contains all three modules. Mentioning
this because the earlier runs' output was not kept and should not be mistaken for build
findings.

## 11. Reproduce

```sh
cd .work/a1-kmods
./run.sh            # exit 0 = all 12 specs built; N = N specs failed to build
```

`run.sh` mounts `src/` read-only and `proof-key/` read-only into the task-1 proof image and
runs `scripts/build-all.sh`. Rebuilding the image is only needed if it was removed:
`podman build -t bluefin-t2-proof:7.2.5 ../image-7.2.5`.
