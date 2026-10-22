# Bluefin + ublue-os/akmods — source map for a T2 hardware layer

Sources read (both shallow clones, one commit each):

- `research/bluefin` = `https://github.com/ublue-os/bluefin.git` @ `13efd26e908c1dc956a731baf365966a8d5e57a3`, 2026-10-16, "chore(deps): update ghcr.io/ublue-os/silverblue-main:44 docker digest" (`git rev-parse --is-shallow-repository` = true). This is the image the README brands **Bluefin Classic** (`bluefin/README.md:2-7`).
- `research/akmods` = `https://github.com/ublue-os/akmods` @ `d3958bd6c1a8301d74d46e3b1ed6d9164a434d2d`, 2026-10-15, shallow.
- Paths below are relative to those two roots, prefixed `bluefin/` and `akmods/`. Nothing here is from memory of the bluebuild era; where a thing is absent I say **not present in tree**.

---

## Executive summary (10 lines)

1. Today's Bluefin build is a **plain multi-stage Containerfile + Just orchestration + numbered shell scripts**, not bluebuild and not bootc-native: one `RUN /ctx/build_files/shared/build.sh`, base `ghcr.io/ublue-os/silverblue-main:<fedora>@digest` (`bluefin/Containerfile:23`), runtime content largely inherited from the pinned `ghcr.io/projectbluefin/common` OCI layer (`bluefin/Containerfile:6,11,16-20`).
2. The matrix is images `{bluefin, bluefin-dx} × flavors {main, nvidia-open} × streams {stable, latest, beta}` (`bluefin/Justfile:5-17`); `dx` is a **build-arg/script branch**, not a Containerfile stage (`bluefin/Justfile:191-194`, `bluefin/build_files/shared/build.sh:53-56`).
3. Out-of-tree modules come from **ublue-os/akmods**: per-(kernel-flavor, Fedora-version, kernel-release) OCI images containing prebuilt **kernel RPMs + signed kmod RPMs**, pulled with `skopeo` and unpacked (`bluefin/build_files/base/03-install-kernel-akmods.sh:17-28`).
4. Bluefin **erases the base kernel** and installs the kernel from the akmods cache, then versionlocks it (`03-install-kernel-akmods.sh:12-15,25-34`). Kernel version and module version are therefore locked together by construction.
5. Secure Boot is a **two-key CMS dual-sign of every module** in akmods (`akmods/build_files/post/dual-sign.sh:15-35`) plus a **Fedora-signature-preserving sbsign of vmlinuz** (`akmods/fetch-kernel.sh:119-161`); trust is delivered as a DER certificate inside `ublue-os-akmods-addons` and enrolled manually into MOK (password `universalblue`, `bluefin/README.md:56-75`).
6. Private keys are **not in git** (0-byte placeholders, `akmods/certs/private_key*.priv`); CI injects `KERNEL_PRIVKEY` / `AKMOD_PRIVKEY_20230518` only on schedule/merge_group/dispatch (`akmods/.github/workflows/reusable-build.yml:111-120`); local builds silently fall back to `*.test` keys (`akmods/build_files/prep/build-prep.sh:58-62`).
7. Image signing (cosign) is a **separate trust root** from module signing: `cosign sign --key env://COSIGN_PRIVATE_KEY` with `secrets.SIGNING_SECRET` (`bluefin/.github/workflows/reusable-build.yml:254-261`); `bluefin/cosign.pub` and `akmods/cosign.pub` are byte-identical (Universal Blue static key).
8. **There is no firmware step.** `bluefin/AGENTS.md:330` documents an `08-firmware.sh` that does not exist; the tree contains no reference to `/usr/lib/firmware`, `brcm`, `apple`, `t2`, `kansei`, `applesmc` or `input-kmod`. Arbitrary blobs can only arrive via `system_files/shared/` (rsynced to `/`, `build.sh:19`), an RPM (`04-packages.sh:118`), or a `COPY --from` layer.
9. CI builds, signs, and pushes to `ghcr.io/${github.repository_owner}/<image_name>`; a fork mostly works by changing `repo_organization`, its own `cosign.pub`/`SIGNING_SECRET`, and the hardcoded key digests in `20-tests.sh:15-16` — every other reference is owner-relative.
10. Biggest derivative risk: T2 modules **must be rebuilt for the exact kernel release ublue publishes for `coreos-stable`**, and must be signed by a key a user can enrol; you own a per-kernel pipeline that chases an artifact someone else rebuilds daily, or you fork akmods and pin/rebuild the kernel yourself.

---

## 1. What the build system actually is (today)

### 1.1 Containerfile: four stages, one build step

`bluefin/Containerfile` (50 lines):

```dockerfile
1:  ARG BASE_IMAGE_NAME="silverblue"
2:  ARG FEDORA_MAJOR_VERSION="42"
4:  ARG BASE_IMAGE="ghcr.io/ublue-os/${SOURCE_IMAGE}"
6:  ARG COMMON_IMAGE="ghcr.io/projectbluefin/common:latest"
8:  ARG BREW_IMAGE="ghcr.io/ublue-os/brew:latest"
11: FROM ${COMMON_IMAGE}@${COMMON_IMAGE_SHA} AS common
12: FROM ${BREW_IMAGE}@${BREW_IMAGE_SHA} AS brew
14: FROM scratch AS ctx
15: COPY /build_files /build_files
16: COPY --from=common /system_files/shared /system_files/shared
17: COPY --from=common /system_files/bluefin /system_files/shared
18: COPY --from=brew /system_files /system_files/shared
19: # bluefin-owned files overlay last so they take precedence over common
20: COPY /system_files /system_files
23: FROM ${BASE_IMAGE}:${FEDORA_MAJOR_VERSION}@${BASE_IMAGE_SHA} AS base
37: RUN --mount=type=cache,dst=/var/cache/libdnf5 \
38:     --mount=type=cache,dst=/var/cache/rpm-ostree \
39:     --mount=type=bind,from=ctx,source=/,target=/ctx \
40:     --mount=type=secret,id=GITHUB_TOKEN \
41:     /ctx/build_files/shared/build.sh
46: RUN rm -rf /opt && ln -s /var/opt /opt
48: CMD ["/sbin/init"]
50: RUN bootc container lint
```

Observations that matter for a derivative:

- **There is no `dx` stage.** `AGENTS.md:269-276` claims stages base → dx; the file has only `common`, `brew`, `ctx`, `base`. DX is `IMAGE_FLAVOR=dx` passed as a build arg (`Justfile:191-194`) and handled inside `build.sh:53-56`.
- **The base is ublue's reprocessed Silverblue**, not Fedora direct: `ghcr.io/ublue-os/silverblue-main` (`Containerfile:1,4,23`). (The keyless/"Fedora-direct" variant described in `bluefin/THEPATTERN.md:17,34-38` is `projectbluefin/bluefin`, a *different* repo; this tree is the key-based one, `THEPATTERN.md:20`.)
- **Layering order for image files** is: common/shared → common/bluefin (overlaid into `shared`) → brew → bluefin-owned `system_files` last (`Containerfile:16-20`). Only `/ctx/system_files/shared/` is rsynced onto `/` (`build.sh:19`); `system_files/dx/` is copied later by `build-dx.sh:8`.
- **Build scripts ship in the ctx stage** (`Containerfile:15`), and the sequence is hard-coded — there is no auto-discovery loop (`build.sh:27-67`).
- `/opt` is made writeable via symlink to `/var/opt` with a comment that this exists for downstream images (`Containerfile:43-46`).
- `bootc container lint` is the final gate (`Containerfile:50`).

### 1.2 Justfile: matrices, argument assembly, rechunk, and the checks

`bluefin/Justfile` (773 lines) is the whole build orchestration:

- Matrices at `Justfile:5-17`:

```
images  = bluefin, bluefin-dx
flavors = main, nvidia-open
tags    = stable, latest, beta
```

- `just build <image> <tag> <flavor> [rechunk] [ghcr] [pipeline] [kernel_pin]` (`Justfile:102`) does, in order:
  - validate combo (`Justfile:109`, `validate` at `70-98`);
  - resolve `common`/`brew` digests from `image-versions.yml` (`114-115`);
  - pick `AKMODS_FLAVOR` — `bazzite` if flavor matches `hwe` (dead branch: no such flavor in the matrix at `9-12`), `coreos-stable` for stable, `main` otherwise (`122-130`);
  - resolve Fedora major (`136`) and look up the pinned base digest keyed `silverblue-main-<fedora>`; **hard fail if missing** (`140-146`);
  - **cosign-verify base, akmods, akmods-zfs, akmods-nvidia-open, common and brew before building** (`149`, `158-168`) using `verify-container` (`487-516`);
  - resolve kernel: if no `kernel_pin`, read `ostree.linux` from the akmods manifest for `<flavor>-<fedora>` (`152-156`);
  - compute version string `<stream>-<fedora>.<YYYYMMDD>` (stable → `<fedora>.<date>`) and a `.N` de-dup suffix via `skopeo list-tags` (`171-186`);
  - assemble `--build-arg`s (`189-210`) and OCI labels including `ostree.linux` and `containers.bootc=1` (`216-230`);
  - `podman build` (`236-246`), optional rechunk (`250-256`).

- `rechunk` (`Justfile:282-434`) mounts the container FS and runs the external `ghcr.io/ublue-os/legacy-rechunk:v1.0.1-x86_64@sha256:2627…` (`Justfile:2`) in three passes: `1_prune.sh`, `2_create.sh` (ostree tree), `3_chunk.sh` (OCI output), then loads it back and runs `secureboot` (`431-434`).
- `secureboot <image> <tag> <flavor>` (`Justfile:518-567`) pulls the image, extracts `vmlinuz`, downloads **both** akmods certs (`537-538`), and requires `sbverify` to pass against **either** cert (`560-563`). This is the per-build Secure Boot gate.
- `generate-build-tags` (`606-661`) produces stream tags, `gts` aliases on Tuesdays/workflow_dispatch, `pr-<n>-*` and `<sha>-*` for PRs.
- `image_name` (`593-602`) = `<image>` for flavor `main`, else `<image>-<flavor>`.
- `setup-cache` (`729-748`) marks `bluefin-dx` as the only cache writer.

### 1.3 build_files: numbered scripts, fixed order

`build_files/base/` (executed by `build.sh`):

| Script | What it does | Key lines |
|---|---|---|
| `00-image-info.sh` | writes `/usr/share/ublue-os/image-info.json`, rewrites `/usr/lib/os-release`, sets **`IMAGE_REF="ostree-image-signed:docker://ghcr.io/$IMAGE_VENDOR/$IMAGE_NAME"`** | `17`, `25-35`, `38-51`, `59-60` |
| `03-install-kernel-akmods.sh` | kernel + akmods (see §2.4) | whole file |
| `04-packages.sh` | ~75 Fedora packages bulk-installed, Tailscale, 2 COPRs, exclusions | `19-118`, `120-129`, `144-168` |
| `05-override-install.sh` | `rm -rf /usr/src /usr/share/doc`, erase kernel-devel from rpmdb, fetch Bluefin PDF + starship, gschema fixes | `8-16`, `19-31` |
| `17-cleanup.sh` | enables units, adds Flathub, disables all third-party/COPR repos | `9-25`, `42-70` |
| `18-workarounds.sh` | bling copy, **removes orphan `/usr/lib/modules/*` with no matching `kernel-core` rpm** (akmods-ostree-post trips on them) | `8-9`, `16-25` |
| `19-initramfs.sh` | `dracut --no-hostonly --kver <kernel> --reproducible --add ostree` | `7-11` |
| `20-tests.sh` | signing-key sha256 asserts, ujust file asserts, package/unit asserts, unwanted packages | `13-19`, `21-29`, `34-68`, `81-93` |

`build_files/shared/`: `build.sh` (driver), `build-dx.sh`, `build-gnome-extensions.sh`, `clean-stage.sh`, `copr-helpers.sh`, `validate-repos.sh`, `utils/ghcurl`.
`build_files/dx/`: `00-dx.sh` (packages, docker-ce, vscode, rocm), `01-tests-dx.sh`.

Notable ordering facts:

- initramfs is generated (`build.sh:51`) **before** DX files are copied (`build.sh:55`), so anything DX adds under `/usr/lib/dracut/dracut.conf.d/` (e.g. `system_files/dx/usr/lib/dracut/dracut.conf.d/80-vfio.conf:1`) is **not** in that initramfs. A T2 dracut config must live in `system_files/shared` (copied at `build.sh:19`).
- `clean-stage.sh:17-20` deletes everything under `/var` except cache/libdnf5/rpm-ostree, and wipes `/tmp` and `/boot`; `clean-stage.sh:9` clears the versionlock.
- `validate-repos.sh:53-87` fails the build if *any* COPR, RPM Fusion, tailscale, vscode, docker-ce, openh264 or coreos-pool repo is left enabled.

### 1.4 image-versions.yml and .gitmodules

`bluefin/image-versions.yml` is the single pin source for base/common/brew (the Justfile reads it with `yq`, `Justfile:114-115,140-146`):

```
6:  - name: silverblue-main-43
8:    tag: 44
9:    digest: sha256:7f829bc…4c612
10: - name: silverblue-main-44
12:   tag: 44
13:   digest: sha256:7f829bc…4c612   # same digest as the "-43" entry
14: - name: common   → ghcr.io/projectbluefin/common:latest @ sha256:fbcef9…
18: - name: brew     → ghcr.io/ublue-os/brew:latest @ sha256:bc6f5a…
```

The `silverblue-main-43` entry pointing at tag 44 and the identical digest is **stale/misnamed today** — worth fixing, not inheriting.

`bluefin/.gitmodules:1-34` registers 9 GNOME Shell extensions as submodules (appindicatorsupport, bazaar companion, blur-my-shell, caffeine, dash-to-dock, gradia, gsconnect, logomenu, search-light). They are consumed as sources and built in `build-gnome-extensions.sh:12-52`; CI checks them out with `submodules: recursive` (`bluefin/.github/workflows/reusable-build.yml:50-53`). The submodule directories are empty in a non-recursive clone.

### 1.5 Variant matrix, honestly

- Images: `bluefin`, `bluefin-dx` (`Justfile:5-8`).
- Flavors: `main`, `nvidia-open` (`Justfile:9-12`); nvidia is signalled only by the image name containing `nvidia` (`03-install-kernel-akmods.sh:60`, `00-image-info.sh:21-23`, `20-tests.sh:70-79`).
- Streams: `stable`, `latest`, `beta` (`Justfile:13-17`).
- `dx` = extra packages + files + services (`build_files/dx/00-dx.sh`), applied inside the same image (`build.sh:53-56`).
- Stale leftovers claiming a wider matrix: `Justfile:122-123` (`hwe`→`bazzite` akmods flavor, no `hwe` image), `bluefin/.github/workflows/clean.yml:20` (deletes packages for `-hwe`, `-asus`, `-surface` variants that are not built any more), `bluefin/AGENTS.md:36-39` (claims F42/43 streams and "two build targets" with a DX stage).
- **Dakota is not in this tree.** No Dakota reference anywhere under `bluefin/`; the only sibling product mentioned in-tree is `bluefin-lts` (`AGENTS.md:395`, `THEPATTERN.md:73-82`).

---

## 2. How out-of-tree kernel modules are built and baked in

### 2.1 What an akmods image is

`akmods/README.md:5-19`: an OCI image carrying **cached kernel RPMs** *and* prebuilt **kmod RPMs**, per kernel flavor and per group (`common`, `extra`, `nvidia-lts`, `nvidia-open`, `zfs`). `akmods/images.yaml:2-5` sets defaults (`kernel_flavor: main`, `version: 44`, `akmods_target: common`); `images.yaml:153-189` is the build matrix of Fedora version × kernel flavor × targets (e.g. `coreos-stable` for 44 builds `common`+`nvidia-lts`+`nvidia-open`+`zfs`, `images.yaml:169-172`).

Kernel flavors: `main`, `coreos-stable`, `coreos-testing`, `longterm-6.18`, `ogc`, `ogc-lts` (`akmods/README.md:21-28`).

### 2.2 The akmods build, step by step

1. **Resolve the kernel** — `akmods/Justfile:76-246` (`get-kernel-version`). Per flavor: coreos → query `quay.io/fedora/fedora-coreos:<stream>` with `rpm -q kernel` inside it (`87-98`) and verify the RPM exists on Koji (`125-165`); longterm → `copr kwizart/kernel-<flavor>` (`179-184`); main → `ostree.linux` label of `quay.io/fedora-ostree-desktops/base-atomic` (`193-196`); ogc → kernel RPM names in an OCI manifest (`185-192`). Output is cached to `KCWD/rpms/cache.json` (`222-245`).
2. **Fetch + sign the kernel** — `akmods/fetch-kernel.sh`, run inside `quay.io/fedora/fedora:<version>` via `podman run` (`akmods/Justfile:254-282`). It downloads/installs the kernel RPMs (`fetch-kernel.sh:22-117`), installs `public_key.crt`/`private_key.priv` into `/etc/pki/kernel/{public,private}` (`96-102`), strips existing signatures **only for non-Fedora kernels** (`119-130`), then:

```bash
133: sbsign --cert "$PUBLIC_KEY_PATH" --key "$PRIVATE_KEY_PATH" /usr/lib/modules/"${kernel_version}"/vmlinuz --output /usr/lib/modules/"${kernel_version}"/vmlinuz
137: if ! sbverify --cert "$PUBLIC_KEY_PATH" /usr/lib/modules/"${kernel_version}"/vmlinuz; then
143: if [[ ${DUAL_SIGN:-} == "true" ]]; then
155:     sbsign --cert "$SECOND_PUBLIC_KEY_PATH" --key "$SECOND_PRIVATE_KEY_PATH" /usr/lib/modules/"${kernel_version}"/vmlinuz --output …/vmlinuz
166: rpmrebuild --notest-install --additional=--buildroot=/tmp/buildroot --batch "${kernel_name}-core-${kernel_version}"
170: dnf reinstall -y /root/rpmbuild/RPMS/"$(uname -m)"/kernel-*.rpm
```

   i.e. the kernel is **dual-signed (two certs) and re-packaged**, then verified again (`172-179`). For `main`/`coreos` the Fedora signature is deliberately kept and an additional one appended (`119-122`).
3. **Build the kmods** — `akmods/Containerfile.in`; a CPP-preprocessed template (`FROM BUILDER AS build_prep`, line 1; `#ifdef COMMON|EXTRA|NVIDIA|ZFS` blocks at `74,98,123,151`). Each `build_files/<group>/build-kmod-*.sh` does the classic akmods dance, e.g. `build_files/common/build-kmod-v4l2loopback.sh:10-14`:

```bash
10: dnf install -y akmod-v4l2loopback-*.fc"${RELEASE}"."${ARCH}"
12: akmods --force --kernels "${KERNEL}" --kmod v4l2loopback
13: modinfo /usr/lib/modules/"${KERNEL}"/extra/v4l2loopback/v4l2loopback.ko.xz > /dev/null
```

   So modules land in `/usr/lib/modules/<kver>/extra/<kmod>/` inside the RPM cache.
4. **Sign the modules** — `akmods/build_files/post/dual-sign.sh` (see §3.2).
5. **Normalise RPM names** — `akmods/build_files/post/build-post.sh:13-25`: fpm rebuilds each kmod RPM **without the kernel version in the package name** (so `kmod-foo` is versioned by `%{version}`/release, and the kmod file paths still carry the kver). Kernel RPMs are copied to `/var/cache/kernel-rpms` (`27-29`).
6. **Publish the RPM tree** — `Containerfile.in:189-192` (`RPM_CACHE`) and `226-227` (`RPMS` = `COPY --from=RPM_CACHE / /`). The result: `/kernel-rpms/*.rpm` + `/rpms/{kmods,common,extra,ublue-os,…}`.
7. **Gate** — `Containerfile.in:194-224` (`test` stage) installs the cached RPMs in a clean builder and runs `build_files/test/check-signatures.sh`, which refuses to pass if any module's CMS signature fails (`check-signatures.sh:11-26` via `dual-sign-check.sh:12-25`).
8. **Tag + manifest** — `akmods/Justfile:328-331`:

```
akmods:<kernel_flavor>-<version>-<arch>
akmods:<kernel_flavor>-<version>-<kernel_release>
```

   plus manifests `:<flavor>-<version>` and `:<flavor>-<version>-<kernel_release-without-arch>` (`Justfile:396-473`, digests printed by CI at `reusable-build.yml:189-204`).
9. **CI** — `.github/workflows/build-akmods-*.yml` are **generated** from `images.yaml` + `workflow-templates/*.in` by `just generate-workflows` (`akmods/Justfile:477-564`; warning banner `build-akmods-coreos-stable.yml:1-6`; daily cron at line 16). Kernel cache key `KCKEY = <kernel_flavor>-<major.minor.patch>` (`reusable-cache-kernel.yml:51,83`).

### 2.3 Version coupling to a kernel release

Three separate couplings, all by kernel release string:

- akmods tag contains the full release (`Justfile:330`), e.g. `coreos-stable-44-6.17.x-300.fc44.x86_64`.
- akmods image label `ostree.linux=<kernel_release>` (`Justfile:326`) is what Bluefin reads to decide which kernel/modules to install (`bluefin/Justfile:153`).
- kernel cache key is only `major.minor.patch` (`reusable-cache-kernel.yml:51`), while the RPM names are full `%{version}-%{release}.%{arch}` — so a release-number bump within the same patch (e.g. `-300` → `-301`) moves the akmods image tag but reuses the cached kernel RPM if the cache key matches.

### 2.4 How Bluefin consumes akmods (exact mechanism)

`bluefin/build_files/base/03-install-kernel-akmods.sh`:

```bash
8:  if [[ "${UBLUE_IMAGE_TAG}" == "beta" ]]; then
9:      dnf5 config-manager setopt updates-testing.enabled=1
12: # Remove Existing Kernel
13: for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra; do
14:     rpm --erase $pkg --nodeps
17: # Fetch Common AKMODS & Kernel RPMS
18: skopeo copy --retry-times 3 docker://ghcr.io/ublue-os/akmods:"${AKMODS_FLAVOR}"-"$(rpm -E %fedora)"-"${KERNEL}" dir:/tmp/akmods
19: AKMODS_TARGZ=$(jq -r '.layers[].digest' </tmp/akmods/manifest.json | cut -d : -f 2)
20: tar -xvzf /tmp/akmods/"$AKMODS_TARGZ" -C /tmp/
21: mv /tmp/rpms/* /tmp/akmods/
24: # Install Kernel
25: dnf5 -y install \
26:     /tmp/kernel-rpms/kernel-[0-9]*.rpm \
27:     /tmp/kernel-rpms/kernel-core-*.rpm \
28:     /tmp/kernel-rpms/kernel-modules-*.rpm
31: dnf5 -y install /tmp/kernel-rpms/kernel-devel-*.rpm
34: dnf5 versionlock add kernel kernel-devel kernel-devel-matched kernel-core kernel-modules kernel-modules-core kernel-modules-extra
38: sed -i 's@enabled=0@enabled=1@g' /etc/yum.repos.d/_copr_ublue-os-akmods.repo
```

Then only three consumers of the cache:

- v4l2loopback, from RPM Fusion + the cached kmod (`41-57`);
- NVIDIA for `nvidia` images, from `ghcr.io/ublue-os/akmods-nvidia-open:…` + `nvidia-install.sh`, and bootc kargs written to `/usr/lib/bootc/kargs.d/00-nvidia.toml` (`59-86`);
- ZFS for `coreos*` flavors, from `akmods-zfs`, with `depmod -a` and `modules-load.d/zfs.conf` (`88-114`).

**Everything else in the akmods `common` cache (openrazer, vhba, wl, xone, xpadneo) is copied to `/tmp/akmods/` and then never installed.** There is no `dnf install /tmp/akmods/kmods/*.rpm` step in this tree. (`AGENTS.md:327` says the script "Installs kernel and akmod packages"; the reality is script-by-script package installs as above.) Downstream, `bluefin/20-tests.sh` does not check for any kmod either.

Practical consequence for a T2 layer: **Bluefin gives you the pattern (`skopeo copy` a kernel-matched RPM cache + `dnf5 install /tmp/akmods/kmods/<glob>.rpm`) but not a general hook**. You either add a step that installs your kmods from a cache you built, or you build them in-image against the pinned kernel.

---

## 3. SECURE BOOT — the complete chain

### 3.1 Key material in the akmods repo

`akmods/certs/` (verified by `ls -l`):

| File | Size | Meaning |
|---|---|---|
| `private_key.priv` | **0 bytes** | placeholder; kernel-signing private key. Real one is a CI secret |
| `private_key_2.priv` | **0 bytes** | placeholder; akmod-signing private key |
| `private_key*.priv.test` | 1704 B | test keys, used when the real one is absent |
| `public_key.der` | 1466 B | **kernel** signing cert (dual-sign key #1) |
| `public_key_2.der` | 1528 B | **module** signing cert (dual-sign key #2) |
| `public_key*.der.test` | 875/819 B | test certs |

Fallbacks are explicit and loud:

```bash
akmods/build_files/prep/build-prep.sh:58: if [[ ! -s "/tmp/certs/private_key.priv" ]]; then
59:     echo "WARNING: Using test signing key. Run './generate-akmods-key' for production builds."
60:     cp /tmp/certs/private_key.priv{.test,}
61:     cp /tmp/certs/public_key.der{.test,}
64: install -Dm644 /tmp/certs/public_key.der   /etc/pki/akmods/certs/public_key.der
65: install -Dm644 /tmp/certs/private_key.priv /etc/pki/akmods/private/private_key.priv
```

and the same pattern in `fetch-kernel.sh:88-92` and `test-prep.sh:42-45`. **`./generate-akmods-key` is referenced but not present in the tree** (no such script found).

CI injection happens only on trusted events:

```yaml
akmods/.github/workflows/reusable-build.yml:112:  if: contains(fromJson('["schedule", "workflow_dispatch", "merge_group"]'), github.event_name)
116:            echo "${{ secrets.KERNEL_PRIVKEY }}" > certs/private_key.priv
117:            echo "${{ secrets.AKMOD_PRIVKEY_20230518 }}" > certs/private_key_2.priv
```

### 3.2 Signing out-of-tree modules (the actual algorithm)

`akmods/build_files/post/dual-sign.sh`, run in the `builder` stage after kmods are built (`Containerfile.in:173-187`):

```bash
10: KERNEL="$(rpm -q "${KERNEL_NAME}" --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}')"
11: SIGNING_KEY_1="/tmp/certs/signing_key_1.pem"
12: SIGNING_KEY_2="/tmp/certs/signing_key_2.pem"
13: PUBLIC_CHAIN="/tmp/certs/public_key_chain.pem"
15: for module in /usr/lib/modules/"${KERNEL}"/extra/*/*.ko*; do
20:     openssl cms -sign -signer "${SIGNING_KEY_1}" -signer "${SIGNING_KEY_2}" -binary -in "$module_basename" -outform DER -out "${module_basename}.cms" -nocerts -noattr -nosmimecap
21:     /usr/src/kernels/"${KERNEL}"/scripts/sign-file -s "${module_basename}.cms" sha256 "${PUBLIC_CHAIN}" "${module_basename}"
22:     /tmp/dual-sign-check.sh "${KERNEL}" "${module_basename}" "${PUBLIC_CHAIN}"
```

- The `.pem` files are assembled by concatenating **private key + its cert** (`build-prep.sh:104-106`); the chain file is cert1+cert2 (`106`).
- The two `.cms` signatures are produced with **both signers in one CMS blob** (`-signer` twice), then `sign-file` appends that CMS blob as the module signature.
- Compression is handled (`.xz` decompress/recompress with `-C crc32`, `.gz` with `-9`) at `17-35`.
- Every module is verified immediately (`22,28,33`) by `dual-sign-check.sh`, which extracts the signature with `scripts/extract-module-sig.pl`, converts PKCS7, and runs `openssl cms -verify … -certfile $PUBLIC_CHAIN -nointern -noverify` (`dual-sign-check.sh:12-25`).
- The kmod RPMs are then rebuilt against the signed payload (`dual-sign.sh:36-46`), reinstalled and re-checked for `modinfo` (`62-69`), and the `test` stage re-verifies all of them on a clean install (`check-signatures.sh:11-26`).
- ZFS has a variant `akmods/build_files/zfs/dual-sign-zfs.sh` selected at `Containerfile.in:181-185`.

### 3.3 MOK enrolment and public key publication

- The cert is published as a **file in the repo** (`akmods/certs/public_key.der`), and Bluefin's docs point users at the raw URL (`bluefin/README.md:69`).
- The runtime package that carries it is `ublue-os-akmods-addons` (spec: `akmods/build_files/common/ublue-os-akmods-addons/ublue-os-akmods-addons.spec`):

```
10: Supplements:    mokutil policycoreutils
12: Source0:        public_key.der
18: Adds the signing key for importing with mokutil to enable secure boot for kernel modules and repo files required to install akmod dependencies.
26: install -Dm0644 %{SOURCE0} %{buildroot}%{_datadir}/ublue-os/%{_sysconfdir}/pki/akmods/certs/akmods-ublue.der
34: install -Dm0644 …/akmods-ublue.der  %{buildroot}%{_sysconfdir}/pki/akmods/certs/akmods-ublue.der
44: %attr(0644,root,root) %{_sysconfdir}/pki/akmods/certs/akmods-ublue.der
```

  i.e. the DER lands at **`/etc/pki/akmods/certs/akmods-ublue.der`** inside the image (and a copy under `/usr/share/ublue-os/…` as a template). `Supplements: mokutil` makes it auto-install on systems that have mokutil.
- The enrolment UX is documented, manual, and one-time: password **`universalblue`**, via `ujust enroll-secure-boot-key`, or `sudo mokutil --timeout -1 && sudo mokutil --import public_key.der` (`bluefin/README.md:56-75`).
- **The `enroll-secure-boot-key` recipe itself is not present in this tree** (no `*.just` files under `bluefin/`; ujust and `/usr/share/ublue-os/just/*.just` come from the `projectbluefin/common` layer, and `20-tests.sh:21-23` only asserts those paths exist). Same for `mokutil` installation — not asserted anywhere in Bluefin's tests.
- Publish/verify side: `akmods/.github/workflows/reusable-build.yml:111-120` (keys), `128-136` push+sign, and `222-345` a `verify-publication` job that runs `cosign verify --key cosign.pub`, a `policy.json` sigstoreSigned check per akmods repo (`283-295`), and a **negative** check that an unsigned `quay.io/fedora/fedora-bootc` image is rejected (`330-342`).

### 3.4 Two independent trust roots — do not conflate them

| Trust root | Signs | Key location | Verified by |
|---|---|---|---|
| **Kernel/module signing (MOK)** | `vmlinuz`, every `.ko` | `akmods/certs/public_key.der` (+`_2`), private in CI secrets `KERNEL_PRIVKEY`, `AKMOD_PRIVKEY_20230518` | `sbverify` (`Justfile:518-567`), `openssl cms -verify` in the akmods `test` stage |
| **Image signing (cosign)** | the OCI image/manifest | `bluefin/cosign.pub` == `akmods/cosign.pub` (byte-identical: same Universal Blue key), private = `secrets.SIGNING_SECRET` | `cosign verify --key` (`Justfile:487-516`), `bootc switch --enforce-container-sigpolicy` (`bluefin/.github/changelogs.py:76,79`) |

The image also enforces a runtime pull policy: `/etc/containers/policy.json` must contain key paths for `ghcr.io/ublue-os` (the base image and update source), and `20-tests.sh:13-19` hard-fails unless the *sha256 of those key files* equals `af78ecfda6eb…` and `b7234670…`. That file comes from the `projectbluefin/common` layer, not this tree (`20-tests.sh:7-11` merely links the upstream rationale).

### 3.5 What a derivative must do to keep T2 modules loadable with SB on

1. **Never break the kernel's existing signatures.** Fedora's sig is kept for `main`/`coreos` flavors (`fetch-kernel.sh:119-130`), and the module keyring trusts MOK/`db`. Reusing the ublue-built kernel is the cheapest route: it is already Fedora+ublue signed.
2. **Sign every T2 module with a key you control**, using the same mechanism: `openssl cms -sign -signer key -binary -outform DER` + `scripts/sign-file` (or `kmodsign`/`sign-file` directly), with the cert embedded in the CMS or available in the chain (`dual-sign.sh:20-21`).
3. **Ship the DER in the image** at a stable path (mirror the `akmods-ublue.der` convention under `/etc/pki/akmods/certs/`), and provide an enrolment command (`mokutil --import`) plus a documented password. There is **no way to enrol silently** — MOK import requires a physical console confirmation.
4. **Add a verification gate** equivalent to `Justfile:518-567` that `sbverify`s your cert against `vmlinuz` **and** your modules (the upstream gate only checks vmlinuz against the two akmods certs).
5. **Keep the kernel and module builds in one pipeline** so a kernel bump cannot ship with modules built for the previous kernel (see §8.2).
6. **Do not sign with the ublue keys** even though the private halves are absent: `certs/private_key.priv` being a 0-byte placeholder means any build you make locally uses `*.test` keys, and a locally-built image with test-signed modules will *not* load on a user's Secure Boot machine unless that test cert is enrolled.

---

## 4. Firmware: what exists, and what a T2 layer must add

**Bluefin has no firmware step at all.**

- No file named `08-firmware.sh`: `find build_files` returns only `00,03,04,05,17,18,19,20` under `base/`. `bluefin/AGENTS.md:330` lists `08-firmware.sh - Firmware configurations` — **stale doc, not in tree**.
- Tree-wide grep for `firmware|/usr/lib/firmware|brcm|apple|t2|kansei|applesmc|bcm|input-kmod` returns only: `AGENTS.md:330`, and a false positive (`python3-pygit2`) — i.e. **no firmware package list, no firmware copy, no dracut firmware config, no Apple/Broadcom anything**.
- No `linux-firmware*` package is installed or removed in `04-packages.sh` (list at `19-118`); the base Silverblue image's firmware is inherited unmodified.
- There is no documented "add firmware to your image" page in the tree. `README.md`, `CONTRIBUTING.md`, `THEPATTERN.md` contain no firmware guidance; docs live out of tree (`README.md:49`, `CONTRIBUTING.md:5`).

Mechanisms that *do* exist for getting arbitrary blobs to `/usr/lib/firmware` (in increasing order of how appropriate they are for a derivative):

1. **`system_files/shared/`** — rsynced onto `/` at `build.sh:19`; the destination path is preserved, so `bluefin/system_files/shared/usr/lib/firmware/<vendor>/<file>` would land exactly there. This is the simplest baked path; note the repo is small by design (content moved to `common`, `AGENTS.md:9`).
2. **A package** — install from Fedora/COPR/RPM Fusion in `04-packages.sh:118` or `copr_install_isolated` (`copr-helpers.sh:4-23`). Best for licensing/cleanup/`rpm -V` integrity, but requires you to own the RPM.
3. **A `COPY --from` OCI layer** — the Containerfile pattern at `Containerfile:11-20`; a vendor firmware OCI image could be added as another stage and copied in, with the same overlay-order caveat.
4. **Runtime host mutation** — not firmware: see the framework hook (§8.3), which writes `/etc/modprobe.d` and udev rules at first boot. Firmware cannot be "installed" this way in an immutable `/usr`, only `/etc/firmware` overrides can.

Constraints a firmware layer inherits: `/usr` is read-only and ostree/bootc-managed, so firmware is only ever baked; modules that need firmware early must have it in the **initramfs**, and the only dracut configuration in the tree is the DX-only vfio example (`bluefin/system_files/dx/usr/lib/dracut/dracut.conf.d/80-vfio.conf:1`, which as noted is written after initramfs generation).

---

## 5. CI/CD and publication

### 5.1 Workflow inventory (`bluefin/.github/workflows/`)

| File | Trigger | Role |
|---|---|---|
| `build-images.yml` | `workflow_dispatch` | umbrella: calls stable + latest + beta |
| `build-image-stable.yml` | `merge_group`, PR to main/testing, **cron Tue 01:00 UTC**, dispatch, call | builds `stream_name: stable` for `brand_name: bluefin` |
| `build-image-latest-main.yml` | `merge_group`, PR to main/testing, call, dispatch (**no cron**) | builds `stream_name: latest`, flavors `["main","nvidia-open"]` |
| `build-image-beta.yml` | PR/push to `beta`, call, dispatch | builds `stream_name: beta` |
| `reusable-build.yml` | `workflow_call` | the actual build/publish engine, 331 lines |
| `generate-release.yml` | called by the stream workflows | creates a GitHub Release with a changelog |
| `clean.yml` | cron Sun 00:15 UTC | deletes GHCR images older than 90 days (`clean.yml:16-24`) |
| `scorecard.yml`, `moderator.yml`, `validate-renovate.yml`, `copilot-setup-steps.yml` | misc | supply chain / AI moderation / renovate config validation |

Matrix in the reusable job: `image_flavor × base_name ["bluefin", "bluefin-dx"]` (`reusable-build.yml:42-47`).

### 5.2 The publish path, with quotes

```yaml
reusable-build.yml:23:  IMAGE_REGISTRY: ghcr.io/${{ github.repository_owner }}
50-53:  checkout with `submodules: recursive`
63-66:  just check
71:      IMAGE_NAME="$(just image_name …)"
116-120: sudo -E just repo_organization="${{ github.repository_owner }}" build-ghcr …
159-168: rechunk (local, 1)
174-176: load-rechunk
182-184: secureboot gate
190-198: generate-build-tags
216-219: lowercase registry (GitHub usernames with capitals break GHCR)
221-225: podman/docker login ghcr.io
227-245: push each alias tag TWICE (podman#27796 digest stability)
250-261: cosign-installer; cosign sign -y --key env://COSIGN_PRIVATE_KEY  <registry>/<image>@<digest>
263-302: oras attach SPDX SBOM, then cosign sign the SBOM artifact
304-310: actions/attest (build provenance)
```

Signing details: `COSIGN_PRIVATE_KEY: ${{ secrets.SIGNING_SECRET }}`, `COSIGN_EXPERIMENTAL: false` (`reusable-build.yml:258-261`). PR events skip login/push/sign (`if: github.event_name != 'pull_request'`, lines 229, 252, 255…), so PR builds validate but publish nothing.

Tag names (`Justfile:606-678`): `latest`/`beta` → `latest`, `latest-<fedora>.<date>`, `latest-<fedora>.<date>` shortened; stable → `stable-daily*`, and on Tuesday-schedule or dispatch also `stable*`, `gts*`; PR → `pr-<n>-<tag>-<version>` + `<sha>-<tag>-<version>`; the image's `ostree.linux` label is the kernel release (`Justfile:219`) and `org.opencontainers.image.version` is `<stream>-<fedora>.<date>` (`Justfile:218`).

### 5.3 What a fork must change to publish its own image

| Area | File:line | What to change |
|---|---|---|
| Registry org | `Justfile:1` (`repo_organization`), overridden by CI at `reusable-build.yml:116`, env at `:23` | set to your org; CI already passes `github.repository_owner`, so a plain fork publishes to `ghcr.io/<you>/bluefin` with no edit |
| Image name(s) | `Justfile:5-8,593-602`; `clean.yml:20` | rename if you want `kaifin` rather than `bluefin`; also update the cleanup package list |
| Vendor in metadata | `Justfile:204` → `IMAGE_VENDOR`; `00-image-info.sh:17,29` | flows from `repo_organization`; `image-ref` becomes `ostree-image-signed:docker://ghcr.io/<you>/<image>` |
| Image signing key | `.github/workflows/reusable-build.yml:250-261`, `bluefin/cosign.pub` | generate a new cosign keypair, store private as `SIGNING_SECRET`, replace `cosign.pub` (that file is the only thing users check) |
| Runtime pull policy | `20-tests.sh:13-19` + `/etc/containers/policy.json` supplied by `projectbluefin/common` | add your registry/key path to policy.json, and **update the hardcoded sha256 constants** or the build fails |
| Base/common/brew pins | `image-versions.yml:6-21`; `Justfile:114-146` | keep ublue/common pins (they are build inputs), add a `silverblue-main-<newfedora>` entry at each Fedora rollover or the build hard-fails (`Justfile:142-146`) |
| Akmods source | `03-install-kernel-akmods.sh:18,62,91`; `Justfile:153-165` | point at your akmods repo/image if you build your own modules; also update the cosign verification target |
| Renovate | `.github/renovate.json5:15-45` | in-tree managers cover the Justfile-pinned image (regex at `:21-24`) and `.gitmodules` tags (`:32-44`); `image-versions.yml` digests are **not** matched by an in-tree manager (digest bumps such as HEAD "#5014" come from elsewhere — `THEPATTERN.md:28` says org-level hosted config, not in this tree). If you self-host, add a manager for `image-versions.yml`. |
| Release/changelog | `generate-release.yml`, `.github/changelogs.py:69-80` | changelog tells users `sudo bootc switch --enforce-container-sigpolicy ghcr.io/ublue-os/$IMAGE_NAME` — hardcodes `ublue-os`; a fork must parameterise this or its users will rebase onto upstream |
| Publish gating | `reusable-build.yml:229,252,255`; `AGENTS.md:307-322` | publishing only happens on `merge_group`/`workflow_dispatch` (latest) or Tue schedule (stable) — a fork with direct pushes to main publishes nothing until it replicates those triggers |

---

## 6. The documented downstream/derivative path

**In this repo: not present in tree.** There is no custom-image starter, no `image-template` reference, no "build your own image FROM Bluefin" doc. What exists:

- `CONTRIBUTING.md:5-7` — "This repository is for building the images, you are probably looking for @projectbluefin/common to change something in Bluefin", plus a link to an architecture diagram on docs.projectbluefin.io. **Image customisation is deliberately delegated to `projectbluefin/common`**, which is where the `system_files`, `ujust` recipes, and (likely) the container policy live.
- The generic inheritance pattern is demonstrated by Bluefin's own Containerfile: `FROM <base>:<tag>@<digest>`, copy files from helper OCI layers, single build script, `COPY /system_files /system_files` overlay (`Containerfile:11-23`).
- `bluefin/THEPATTERN.md:64-71` lists the kinds of "system files added" that a derivative layer would contain (dconf, `/usr/bin` helpers, dnf copr vendor config, flatpak preinstall, just recipes) — but it is a comparison report about a *different* repo, not a how-to.
- For the kmod side, the only in-tree "how to consume this" doc is in akmods: `akmods/README.md:118-142`, quoted:

```
COPY --from=ghcr.io/ublue-os/akmods:TAG / /tmp/akmods-common
RUN dnf install /tmp/rpms/ublue-os/ublue-os-akmods*.rpm
RUN dnf install /tmp/rpms/kmods/kmod-v4l2loopback*.rpm
```

  and "To install one of these kmods, you'll need to install any of their specific dependencies … and ensure you are on a compatible kernel" (`README.md:120`). Adding a kmod upstream is explicitly invite-only-ish: "KMODs … will likely only be included if there is a need/desire to include them within the Universal Blue Project. Generally, KMODs for hardware enablement will be considered" (`README.md:259-265`).

Practical derivative path implied by the tree (all mechanisms quoted above): either fork `projectbluefin/common` + this repo, or build a new Containerfile `FROM ghcr.io/ublue-os/bluefin:latest` + `rpm-ostree install`/`dnf install`/`COPY system_files` + rebuild the initramfs and sign, or (cleanest) take this repo's structure and point it at your own akmods. Note that a *rebase-only* derivative (`bootc switch` to your image) still needs your cosign key in the host policy and the `--enforce-container-sigpolicy` flag to resolve, because `image-ref` is `ostree-image-signed:` (`00-image-info.sh:17`).

---

## 7. Existing T2 support: none in either tree

Search run over both clones for `\bt2\b`, `kansei`, `apple`, `applesmc`, `brcm`, `bce`, `input-kmod`, `macbook`, `t2linux`, `firmware`:

- `bluefin/`: **zero** genuine hits. The only match is `AGENTS.md:330` (`08-firmware.sh`, which does not exist). No package in `04-packages.sh:19-118` or `00-dx.sh:12-65` is an Apple/T2 package. No service, no udev rule, no module-load file, no `modprobe.d` fragment for Apple hardware. The only per-hardware code is **Framework** (`system_files/shared/usr/share/ublue-os/system-setup.hooks.d/10-framework.sh`), which is a good template for what a T2 hook would look like — including karg mutation (`10-framework.sh:14,18-39`).
- `akmods/`: the only Apple-adjacent module is `wl` (legacy Broadcom `broadcom-wl`, `akmods/README.md:53`), pulled from RPM Fusion nonfree and built via `akmods/build_files/common/build-kmod-wl.sh`. **That is not T2** — T2 Macs use `brcmfmac` with Apple-specific firmware, not `wl`.
- `applesmc` is an in-tree Fedora kernel module (not referenced anywhere in these trees); `apple-bce`, `apple-ibridge`, the T2 touchbar drivers and the Apple EFI/firmware extraction are entirely absent.

Conclusion: today's Bluefin carries **whatever the Fedora kernel + silverblue/ublue base + projectbluefin/common provide**, and that is *not* KaiT2en's stack. The "thinner T2 support Bluefin has today" is not visible in this tree at all — if it exists it must be in `projectbluefin/common` or in an RPM the base image ships; neither can be verified from these clones. That is a concrete research gap for the design.

---

## 8. Constraints a derivative must respect

### 8.1 The layering model is the whole architecture

- Image content comes from four overlays in a fixed order (`Containerfile:16-20`): common/shared → common/bluefin → brew → this repo. **Only `system_files/shared/` is rsynced to `/`** (`build.sh:19`); `system_files/dx/` is applied later only for DX (`build-dx.sh:8`).
- Build logic is an ordered list (`build.sh:27-67`), not a plugin system. A new step must be **added to that list**, and it must respect the stage boundaries:
  - before `19-initramfs.sh` if it affects dracut/modules/firmware;
  - before `17-cleanup.sh` if it enables repos (cleanup + `validate-repos.sh` will otherwise fail the build);
  - after `03-install-kernel-akmods.sh` if it needs the pinned kernel present.
- `validate-repos.sh:53-118` is a hard gate: any repo left `enabled=1` fails the build. A T2 COPR/repo must be isolated the way `copr_install_isolated` does it (`copr-helpers.sh:14-20`) and disabled in `17-cleanup.sh`.
- `clean-stage.sh:17-20` wipes `/var` (except caches), `/tmp` and `/boot`; `05-override-install.sh:8-11` already removes `/usr/src` and kernel-devel — plan for module sources not surviving.
- Tests are part of the build (`20-tests.sh`, `01-tests-dx.sh`), and **they contain hardcoded values that will break a fork** (`20-tests.sh:15-16` key sha256s; `20-tests.sh:56-62` unwanted package list; `20-tests.sh:81-93` unit list). Add T2 assertions there.

### 8.2 Kernel/module lockstep is enforced by construction — and is the fragile part

- Bluefin does not use Fedora's kernel from the base image: it erases it (`03:13-15`) and installs `kernel-rpms` from the akmods OCI (`03:18-28`), then `versionlock`s all kernel packages (`03:34`).
- The kernel release selected is whatever `ostree.linux` the akmods manifest for `<flavor>-<fedora>` carries (`Justfile:153`), or an explicit `kernel_pin` (`Justfile:152-156`; example pin commented at `build-image-stable.yml:34-35`).
- Therefore: **a module built against anything other than that exact release will not load** (`modinfo`/vermagic mismatch), and because modules are signed, any kernel change requires re-signing.
- A derivative must either (a) track ublue's akmods builds and rebuild T2 modules for each new kernel release before the next Bluefin image, or (b) fork akmods and publish its own kernel+module cache (then it owns CoreOS kernel tracking, the `coreos_stable_kernel_pin` mechanism `akmods/README.md:94-116`, and the daily cron `build-akmods-coreos-stable.yml:16`), or (c) drop the kernel-replacement step and build modules against Fedora's kernel — which means giving up Bluefin's kernel pin and accepting whatever the base Silverblue ships that week.

### 8.3 ostree `/etc` handling and host mutation

- Bluefin writes config straight into `/etc` in the image (`system_files/shared/etc/profile.d/*`, `etc/rpm-ostreed.conf`, `etc/bazaar/*`), which on ostree/bootc means "default, admin-editable, 3-way merged on upgrade" — not "immutable truth". `rpm-ostreed.conf:6` sets `AutomaticUpdatePolicy=stage`; `rpm-ostreed.conf:11-17` documents that local layering (`LockLayering=false`) is unsupported and "can lead to upgrade issues".
- The tree **does** mutate the host at first boot via the ublue hooks: `system-setup.hooks.d/10-framework.sh:14,36` runs `rpm-ostree kargs` and even reboots; it writes `/etc/udev/rules.d/*` (`:59-62`) and removes `/etc/modprobe.d/alsa.conf` (`:49-52`). Privileged hooks go through `pkexec /usr/bin/ublue-privileged-setup` (`99-privileged.sh:7`); user hooks run as the user (`10-vscode.sh:3-5`).
- There is **no written "no host mutation" rule** in either tree. The nearest normative statements are `AGENTS.md:307-322` (publish rules), `THEPATTERN.md:332` (declarative pins), and the rpm-ostreed warning above. For the design doc, state the rule you intend to hold to rather than citing one.
- Baked kernel args exist as `-toml` files in `/usr/lib/bootc/kargs.d/` (`03:83-85`, NVIDIA) — that is the clean, declarative alternative to the Framework hook's `rpm-ostree kargs`.

### 8.4 Size, build time, and the "small repo" design

- No explicit image-size cap in either tree. What exists: the **rechunker** pass (`Justfile:2,356-413`) whose purpose is ostree-consistent, prunable layers; and `clean-stage.sh:17-20` (wipe `/var`, `/boot`, `/tmp`). `AGENTS.md:9` records the repo itself as "75MB total, 74MB system files" — the heavy content lives in `projectbluefin/common`.
- Build cost is documented as **30–60 min and 20GB+ disk for base, 45–90 min for DX** (`AGENTS.md:78-80`), 8GB+ RAM (`AGENTS.md:116`). CI mitigates with a DNF package cache (`reusable-build.yml:83-136`) that only `bluefin-dx` may write (`Justfile:729-748`).
- Test guidance is explicit: don't run full builds casually; validate with `just check` + `pre-commit run --all-files` (`AGENTS.md:68-76,178-182`). `pre-commit` config in-tree is minimal: JSON/TOML/YAML checks, EOF, trailing whitespace (`bluefin/.pre-commit-config.yaml:3-11`). (Note: `THEPATTERN.md:189-209` describes a richer hook set — that belongs to the other repo.)

### 8.5 Repo rules that bind a derivative reusing this structure

- Conventional commits, enforced on commit **and PR title** (`AGENTS.md:391-393`); `semantic.yml` sets `titleOnly: true`.
- "Always be surgical with the least amount of code" (`AGENTS.md:393`).
- Renovate rules: never hand-edit a `renovate/*` branch, never merge `main` into one, don't close Renovate PRs as a "fix"; PRs are authored by `app/ubot-7274` not `app/renovate` (`AGENTS.md:370-387`); `rebaseWhen: behind-base-branch` (`renovate.json5:14`).
- Docs and LTS live elsewhere: `ublue-os/bluefin-docs`, `ublue-os/bluefin-lts` (`AGENTS.md:393-394`).
- AI attribution footer requirement (`AGENTS.md:396-408`).

---

## Exact hook points for a T2 layer (in order)

Two viable shapes. **Shape A** = derivative of `bluefin` only, modules built in-image (or from your own cache) against Bluefin's pinned kernel. **Shape B** = fork `akmods` too, publish `akmods-t2`, and consume it from a Bluefin derivative. Ordering below is the order to implement, with the shape each item is needed for.

1. **Decide the kernel story first (A/B).**
   - A: reuse ublue's `coreos-stable` kernel and add a T2 kmod cache keyed to `ostree.linux` (mirror `03-install-kernel-akmods.sh:18-21`).
   - B: fork `akmods`, add a target in `akmods/images.yaml:153-189` and a builder `akmods/build_files/<group>/build-kmod-t2.sh` patterned on `build_files/common/build-kmod-v4l2loopback.sh:10-14`, then `just generate-workflows` (`akmods/Justfile:477-564`).
   *Rationale:* everything downstream (signing, tags, versionlock) assumes kernel and modules are produced together.

2. **`Containerfile`** — either add a T2 OCI stage next to `common`/`brew` (`Containerfile:11-20`) or point the base arg at your own image. Keep the overlay order: your files must land in `/system_files` **after** `common` (`Containerfile:20`) so they win.

3. **`Justfile`** — `repo_organization` (`:1`), image names (`:5-8`, `:593-602`), akmods source/flavor (`:122-130`, `:153-165`), and add a `verify-container` for your akmods image (`:159`) if you publish one. Add a `secureboot` variant that checks your cert (`:520-567`).

4. **`image-versions.yml`** — add pins for any new OCI input (your `akmods-t2`, any firmware image); keep `silverblue-main-<fedora>`, `common`, `brew` (`:6-21`). Rename the misnamed `silverblue-main-43` entry while you are there.

5. **`build_files/base/06-t2-modules.sh`** (new) + **one line in `build_files/shared/build.sh`** after `03` (`build.sh:31`). The script must:
   - `skopeo copy --retry-times 3 docker://<your-registry>/akmods-t2:"${AKMODS_FLAVOR}"-"$(rpm -E %fedora)"-"${KERNEL}" dir:/tmp/akmods-t2` (mirror `03:18`),
   - `dnf5 -y install /tmp/akmods-t2/kmods/*.rpm` (Bluefin only does this for v4l2loopback, `03:55` — this is the missing generalised step),
   - `depmod -a -v "${KERNEL}"` (mirror `03:112`),
   - write `/usr/lib/modules-load.d/<module>.conf` for anything that must autoload (mirror `03:113`).

6. **`system_files/shared/usr/lib/dracut/dracut.conf.d/9x-t2.conf`** (new). Must be in `shared`, not `dx`, and must exist before `19-initramfs.sh` (`build.sh:51`); use `force_drivers+=` / `add_drivers+=` and `install_items+=` for firmware. Pattern: `system_files/dx/usr/lib/dracut/dracut.conf.d/80-vfio.conf:1`.

7. **`system_files/shared/usr/lib/bootc/kargs.d/00-t2.toml`** (new) if kargs are needed. Declarative baked kargs, as NVIDIA does (`03:83-85`), instead of the first-boot `rpm-ostree kargs` mutation in `10-framework.sh:36`.

8. **Firmware** — `system_files/shared/usr/lib/firmware/...` (rsynced by `build.sh:19`), or a T2 firmware RPM added in `04-packages.sh`. Confirm the blobs are in the initramfs if any module that needs them is loaded there (step 6).

9. **Module signing + MOK** — a `sign-t2.sh` modelled on `akmods/build_files/post/dual-sign.sh:20-22` and a post-install verify modelled on `dual-sign-check.sh:12-25`; ship your DER under `/etc/pki/akmods/certs/` (mirror the spec's `akmods-ublue.der`, `ublue-os-akmods-addons.spec:26,34,44`); add a `ujust enroll-t2-key`-style recipe **in the repo that actually ships ujust** (`projectbluefin/common` or your own `system_files/shared/usr/share/ublue-os/just/*.just` — none in this tree), and document the MOK password as `README.md:58-75` does.
   - If you fork akmods, replace the two cert/key pairs: `akmods/certs/{public_key.der,public_key_2.der,private_key*.priv}` and CI secrets `KERNEL_PRIVKEY` / `AKMOD_PRIVKEY_20230518` (`akmods/.github/workflows/reusable-build.yml:116-117`), and update `akmods/fetch-kernel.sh:133,155`'s dual-sign behaviour only if your kernel needs it.

10. **Image cosign key** — new `cosign.pub` at the repo root (`bluefin/cosign.pub`), private as `SIGNING_SECRET` consumed at `reusable-build.yml:257-261`; add your registry to `/etc/containers/policy.json` (supplied by `common`) and mirror the assertion in `20-tests.sh:13-19` with your key's sha256.

11. **`build_files/base/20-tests.sh`** — add: `rpm -q kmod-…` / `modinfo` assertions, presence of your DER, the two `mokutil`-adjacent files, and `sbverify` of `vmlinuz` against your cert (extend the `Justfile:520-567` logic). Also re-baseline the hardcoded key digests if you changed keys.

12. **CI** — add the T2 secure-boot gate beside `secureboot` (`reusable-build.yml:178-184`), add your secrets, and make sure the publish triggers match your release cadence (`reusable-build.yml:229-261`; `AGENTS.md:307-322`). If you publish `akmods-t2`, copy `akmods/.github/workflows/reusable-build.yml` and keep the `verify-publication` job (`:222-345`).

13. **`.github/renovate.json5`** — add a manager for `image-versions.yml` if self-hosting (in-tree config only covers `Justfile` and `.gitmodules`, `:15-45`), and update `clean.yml:20`'s hardcoded package list to your image names.

14. **Docs/metadata** — `00-image-info.sh:7-17` (name, URLs, `image-ref`), `20-tests.sh:21-23` if you move ujust, and `AGENTS.md` (the in-tree copy is already stale: `:36-39,269-276,330`; do not propagate its errors).

---

## Gaps this analysis could not close from the tree

- `projectbluefin/common` is an OCI layer only (`Containerfile:11,16-17`), not cloned. Its `system_files` holds the ujust recipes (including `enroll-secure-boot-key`), `/etc/containers/policy.json`, and most desktop content — **none of that is verifiable here**.
- Whether the pinned `ghcr.io/ublue-os/silverblue-main` base already carries Apple/T2 packages or firmware cannot be determined without pulling the image.
- `generate-akmods-key` (referenced at `build-prep.sh:59`) does not exist in the akmods tree; key generation is undocumented in-tree.
- The exact T2 module list, firmware blobs and helper apps are out of scope here (task-1/task-3).
