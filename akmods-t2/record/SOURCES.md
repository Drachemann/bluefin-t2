# SOURCES.md — provenance of every byte built in this task

Everything under `src/` is a **verbatim copy** of the pinned research clone. No file was
edited, no patch applied, no build performed inside `research/`.

| Field | Value |
|---|---|
| Clone | `research/KaiT2en-Fedora` (shallow, read-only reference) |
| Commit | `ba9d2d830ae5b4ccacf7f82ccc305270496397ff` (`refs/heads/main`, read from `.git/refs/heads/main`) |
| Copy method | `cp -a` from `modules/<spec>/`, plus `t2-services/t2-ave/kernel/t2bce_ave` for AVE |
| Integrity check | per-directory SHA-256 of the sorted `(sha256, path)` list, compared against the clone after the build |

`tree_sha256` below is `sha256( concat of "sha256sum <file>" for every file, sorted by path )`.
An identical value before and after the build is the proof that no source was modified.

| Staged dir | Files | Bytes | tree_sha256 |
|---|---|---|---|
| `src/t2bce_stack` | 3 | 1 629 | `02a6dd3268aff32efc15fe7afebb7982c0fe4c971f678991140b409c7af2c45c` |
| `src/t2touchbar` | 8 | 130 710 | `262325d23ea42bce2f3c19478a92948728a7d71ac0c3f1d12d9dce0fd90e82e4` |
| `src/hid_t2magicmouse` | 4 | 117 804 | `932027b98b735fca7ef37bcd8906915f5a6b8c91a5cb1c3b51b326c253029b2d` |
| `src/t2bdrm` | 4 | 30 534 | `83469b9aaa94edc77e4b3e2f41ae7a79ee60d5b9aeb6ffd275f58660c425705f` |
| `src/t2smc` | 5 | 109 566 | `b68855113a7aa76f8a4bde7ea22e1ded31c4a4e276b88bd3290f76f57cf16c76` |
| `src/t2sbs` | 5 | 24 425 | `5f9d6df0020ae1531f5605c901539c37af669ee5ae0884a886c99db381458c48` |
| `src/t2mfi_fastcharge` | 4 | 7 142 | `d3e02114a6bbea6892261eddf84d706b279467bb39677f022fde71ff97c500d1` |
| `src/t2gmux` | 4 | 49 939 | `2d606721a291ac4f2f97077294c6dfa5a84beb2172b30a66715ade192c2ea272` |
| `src/t2thunderbolt` | 5 | 11 716 | `5b77122da11f6c26f79d45eb9e5c8168a5f7fa10a830dc5e00b15aff8c5ff733` |
| `src/t2smp` | 3 | 4 477 | `75af43f4d7487532e08596c1373bc48ebcb0151f4274e453cd188e76536160dc` |
| `src/t2_precision_trackpad` | 6 | 45 237 | `ab6e6fb1322903ff7c747219450733fa2ee050da7cd4a4f5743a2b6352bb42ab` |
| `src/t2_trackpad_actuator` | 7 | 16 332 | `f35a52989997e46ccdeba72df43af69c8eb89bafd94e33cd14599e003b6a44db` |
| `src/t2bce_ave` | 9 | 99 595 | `0ca7b51afdc35ea8a1df90cb4e0e4819ef2cef6b07375f0a0e3247be0c22fdfc` |
| `src/components/t2bce_dma` | 4 | 36 156 | `c90d041398d780e57614e9b9c79c3b1e471267e6f32716dc825d460069468cd0` |
| `src/components/t2bce_core` | 9 | 66 244 | `4c70e514abd25737717012f0e0ca869577432786595a37f0e3e0661319035802` |
| `src/components/t2bce_vhci` | 8 | 119 170 | `bc6acc2a25d47e3ff1e8e8da8f18e5f870f6713c73e316211d19cb47a0505db3` |
| `src/components/t2bce_audio` | 13 | 104 897 | `006f1d9bc2d13b4cc5c6fd667d577457eb22732261e7518bb9f4d725fb304176` |

## Why `components/` and the separate `t2bce_ave` exist

`t2bce_stack` is the one spec that is not a single self-contained directory. Its Makefile is
five `obj-m += <dir>/` entries, so Kbuild expects the five component directories **below**
`t2bce_stack`. Upstream says so in two places and stages them exactly this way:

* `modules/t2bce_stack/README.md`: *"They are staged below this directory by the Fedora DKMS
  installer."*
* `scripts/fedora/install-dkms-modules.sh` (`copy_module_source`, the `t2bce_stack` branch):
  copies `t2bce_dma`, `t2bce_core`, `t2bce_vhci`, `t2bce_audio` from `modules/`, and
  `t2bce_ave` from `t2-services/t2-ave/kernel/t2bce_ave`, into `/usr/src/t2bce_stack-<ver>/`.

`t2-services/t2-ave/kernel/t2bce_ave/Makefile` corroborates this: it defaults its core
include path to `../t2bce_core` when staged next to it, and only falls back to
`../../../../modules/t2bce_core` for a standalone repository build.

So the staging in `scripts/build-all.sh` reproduces the installer layout. **It copies; it
does not patch.** `t2bce_ave` is a build input of the `t2bce_stack` spec, not a 13th spec —
the deliverable is still 12 RPMs, and AVE ships inside `kmod-t2bce-stack`.

`t2bce_audio-alsa-ucm-conf/` and `t2sep/` are present in the clone but are **not** T2 kernel
modules in §14's set and are not built here (UCM configuration and a userspace/tooling
component respectively).
