# Skills and capabilities for the `bluefin-t2` agent mode

A routing decision for each area of work this project actually does, the skills it should not
invite, at most three bundled mode skills, and the row set. Nothing was installed or modified;
this file is the only change.

**Read for this decision:** `AGENTS.md`, `CLAUDE.md`, `docs/designs/kait2en-bluefin-v2.md`
(§4 models, §5 architecture and signing, §6 resolutions, §7 product, §9 test strategy, §10 docs,
§13 success criteria, §14 tasks), the four `docs/reviews/`, and — for shape and depth only —
`.dsh/agent-modes/{dakota,ecommerce}/` in the `dsh-gstack` checkout (both bundles and their two
skills), plus the row fragments it ships.

**Not run:** no skill was loaded, no mode generated, no gbrain call was made. The directory is
not a git repository, so nothing here was verified against a diff.

**Thesis.** This project's risk is not that the agent does not know the gstack process. It is that
an agent does something plausible on a T2 Mac and locks the author out of his only working
machine, or reports a hardware claim that no run supports. The mode's differentiation is therefore
a *safety-and-evidence boundary*, not a wider skill catalog. Two bundled skills, two rows removed
from the default set, and a routing table that says "no skill owns this" where that is the truth.

---

## 0. What the work actually is

The four lanes in §14 map onto the recurring work named in the brief:

| Lane | Work | Failure that actually happens |
|---|---|---|
| L1 kmods (T1–T3) | one DKMS source tree → 12 specs → 18 signed objects, for the **image's** kver | built for `uname -r`; vermagic mismatch; wrong `Requires:` |
| L2 image (T4–T7) | both Containerfile stages, 9 steps, `90-tests.sh`, kargs | a green build with no keyboard in the initramfs |
| L3 install (T8, T9, T12, T13) | firmware crossing, route 2, HIL harness, ISO | a black screen with no evidence, because a T2 Mac has no serial console |
| L4 surfaces (T10, T11, T14, T15) | `bluefin-t2 report`, the hub, nine docs pages, the rotation drill | a claim published ahead of its recorded run |

Every routing decision below is chosen against those four failure columns, not against the
vocabulary of the request.

---

## 1. The routing table

The catalog is the `gstack-*` suite, `coder`, `codex-cli-calling`, `grok-cli-calling`,
`kimi-cli-calling`, `hermes-cli-calling`, `dsh-badge`, `memory-consolidate`. "Bundled companion"
is one of this mode's own skills (§3) that supplies the project-specific half.

| # | Area of work | Skill that fires | Trigger phrase a user would type | Why it wins |
|---|---|---|---|---|
| 1 | A kernel module that will not load after a kernel bump | **`gstack-investigate`** | "t2hid stopped loading after the kernel bump — the keyboard is dead on the bench Mac" | Iron Law: no fix without a root cause, and its four phases fit a bisectable regression. Beats `gstack-qa` (nothing is being driven) and beats the triage skill alone, because the triage skill can say *which* assertion failed but not run a hypothesis loop. The triage skill goes first for the evidence, then this. |
| 2 | The image build fails | **`gstack-investigate`** — *unless the error is one of ours* | "CI is red on the image build and I can't see why" | Wins when the failure is unexplained or new (base-digest bump, akmods drift, a step that worked yesterday). If the message is one of §5's named errors — `no kmod cache for 7.2.5-200.fc44`, a failed `rpm -qpR`, an `lsinitrd` miss, a `bootc container lint` failure — the design already fixed the cause and the work is reading the string. Root-causing an intended refusal is how a safety property gets deleted. |
| 3 | The installer USB boots to a black screen | **`gstack-investigate`**, entered after the triage skill's Step 0 | "the installer USB boots to a black screen on the bench Mac" | The only catalog skill whose method survives having no application and no journal. It is third, not first: a black screen on a T2 Mac has no serial console, so the evidence is the attempt marker and a photograph (§6 R2-11) and the safe next action is Tier 3's recovery contract, not an experiment. Beats `gstack-browse` emphatically — the screen is not a page. |
| 4 | Reviewing a change to the Containerfile before it lands | **`gstack-review`** | "review this Containerfile diff before it lands" | The one diff-review skill in the suite, and it is structural rather than test-driven. Beats `gstack-plan-eng-review` (that reviews a plan, and the plan is already locked in v2) and beats `gstack-qa` (it would want a running system). Caveat that belongs in the bundled skill: the Containerfile's real invariants are step order (cache at 05, `90-tests.sh` at 07, lint at 08), `KVER` from the digest label, and no build residue — a general reviewer will not know to look. |
| 5 | Adding a new model to the supported set | **No catalog skill owns it.** The rubric is §4; the gate is the bundled verification skill's Tier 2 | "can I claim MacBookPro15,2 as validated yet?" | A model enters `validated` only by a digest-pinned Tier 2 run for *that* model (§4, §13), and `models.d` changes `unmeasured` → measured by that run. No review skill can validate a hardware claim; invoking one would manufacture a green light. Nearest skill is `gstack-plan-eng-review`, and only when the model needs a *mechanism* — class B's patched `amdgpu`, `t2gmux`, the 16,1 karg exception. For 15,2/15,4/16,3 there is nothing to plan. |
| 6 | Writing the user-facing docs | **`gstack-document-generate`** | "write INSTALL.md — the numbered route-1 page" | Nine pages that do not exist yet, each with a declared audience and a Diataxis slot (§10). Generation, not audit. Beats `gstack-document-release`, which syncs an existing doc set to what shipped — that is the post-ship job, and it is the right second call after the first green Tier 3. |
| 7 | A security pass on the signing-key handling | **`gstack-cso`** | "security pass on the signing-key handling" | The suite's only audit skill with a threat-model step, and the key lifecycle has real adversaries (fork-PR exfil, a stale MOK entry, a rotation that locks users out). Beats `gstack-review`, which is scoped to a diff. Honest scope: the deliverable is CI-secret exposure, DER distribution, dual-sign ordering, `mokutil --sb-state` reporting and the rotation rollback — not an OWASP pass, and the skill's web-shaped findings will mostly not apply. |
| 8 | A second opinion on a tricky suspend/resume diagnosis | **Not a skill — the `model_second_opinion` tool**, inside a `gstack-investigate` run | "get a second opinion on this suspend/resume theory" | A suspend failure on one machine, not reproducible on demand, is the textbook advisory case: consequential, contested, and cheap to be wrong about. There is no "second opinion" skill in the catalog and inventing one would be the ceremony the tool exists to avoid. Fire it after a hypothesis exists, not before. A decline is the answer — do not retry, and do not treat the missing opinion as a hole. |
| 9 | Shipping a release | **`gstack-ship`** | "ship the release" / "cut v0.1 and tag it" | Commit, VERSION, CHANGELOG, push, PR — the mechanics that still exist here. Beats `gstack-land-and-deploy`, which merges and then health-checks a **deployed service**; this project publishes images, an ISO and a kit, and its gate is a recorded Tier 2 run, not an HTTP endpoint. Ship produces the tag; the ladder decides whether the tag may claim a model. |

### Contested calls, and who wins

- **`gstack-investigate` vs plain reasoning (#1, #2).** Investigate wins on any regression where
  the cause is not in the error text. Plain reasoning wins, and the skill must *not* fire, when the
  error is a named refusal the design wrote on purpose. This is the single most expensive routing
  mistake available here, because the "fix" to a failed `lsinitrd` assertion is to delete the
  assertion.
- **`gstack-qa` / `gstack-qa-only` vs the bundled ladder (#1, #3, #5).** QA wins nowhere in this
  project. Its surfaces are browser, API, CLI, job and worker; this project's runtime test is a
  machine that boots and a photograph when it does not. The ladder wins because it can name the
  four tiers and say which one a change is allowed to claim.
- **`gstack-review` vs `gstack-cso` (#4, #7).** Review is per-diff and catches structural defects;
  cso is per-threat-model and asks who can sign what. A key-handling change can pass review and
  fail cso, which is why both exist and neither substitutes.
- **`gstack-document-generate` vs `gstack-document-release` (#6).** Generate builds the page;
  release proves the page still matches the shipped diff. The design's own sequencing (§10: pages
  2, 3, 7, 8 only *after* the first green Tier 3) is the rule that keeps generate from documenting
  a screen that does not work.
- **`gstack-ship` vs `gstack-land-and-deploy` (#9).** Land-and-deploy's whole value is waiting for a
  deploy and running canaries. There is no deploy to wait for. Shipping here is a tag, a release
  asset set, and a Tier 2 record.
- **`gstack-autoplan` is not the shortcut it looks like.** It runs CEO, design, eng and DX reviews
  in one pass. On this project it would spend most of its budget on a design and a DX section with
  no surface, and return "fully reviewed" having never looked at the lockout boundary. Run the
  individual reviews instead — and note that all four were already run once, into `docs/reviews/`.

### What fires when nothing else does

- "which subsystem is dead?" → the bundled `bluefin-t2-hw-triage` skill, not a catalog skill.
- "is this change allowed to claim that?" → the bundled `bluefin-t2-verification` skill.
- "is this ambitious enough?" / "lock the plan" → `gstack-plan-ceo-review` / `gstack-plan-eng-review`
  remain valid; the plan is locked in v2, so these fire on a *new* plan, not on v2.

---

## 2. Which skills should NOT be reachable here

The project has no web UI, no browser flow, no iOS app, no marketing site, no SQL database, and no
deployed service. The exclusions below are the mode's own declaration — the host catalog still has
them, and the persona must say which ones are out of scope so the agent does not reach for them
because a phrase matched.

### 2.1 Exclusion list

| Skill(s) | Why not here |
|---|---|
| `gstack-browse`, `gstack-scrape`, `gstack-open-gstack-browser`, `gstack-pair-agent`, `gstack-setup-browser-cookies`, `gstack-skillify` | No web surface to drive, scrape or codify. **Actively wrong for #3**: "the installer boots to a black screen" reads like a browser job and is not one — the screen is pre-userspace, and a browser tool would return a confident nothing. |
| `gstack-design-consultation`, `gstack-design-html`, `gstack-design-shotgun`, `gstack-design-review`, `gstack-plan-design-review` | The product's only authored UI is one hub window plus a terminal-shaped report (§7). Both are specified, both are QA'd by `desktop-file-validate` and Tier 2, and neither is a design-system job. A visual-polish pass has nothing to polish and would invite a redesign of a surface the design deliberately kept thin. |
| `gstack-devex-review` | Audits a live developer experience in a browser. The contributor on-ramp here is a docs page and a `just` recipe (§10), and its quality is gated by the on-ramp being executed, not by a TTHW screenshot. |
| `gstack-benchmark`, `gstack-canary` | Core Web Vitals and post-deploy console watching. The equivalents here are image-size delta ≤250 MB and a Tier 2 run, and both are already assertions in `90-tests.sh` and the release gate. |
| `gstack-qa`, `gstack-qa-only` | Browser/API/CLI/job/worker QA. This project's "flow under test" is a machine that boots and a photograph when it does not. A QA run would either find nothing or report green from a harness that never touched the hardware. |
| `gstack-land-and-deploy`, `gstack-landing-report`, `gstack-setup-deploy` | No deployed service, no health endpoint, no version-slot queue. Shipping is a tag plus assets (§10), gated by Tier 2/Tier 3. |
| `gstack-ios-qa`, `gstack-ios-fix`, `gstack-ios-clean`, `gstack-ios-sync`, `gstack-ios-design-review` | No iOS app. The T2 Macs are x86_64 Fedora hosts and the only macOS code is the kit's shell. |
| `gstack-autoplan` | See §1: it would run design and DX reviews that have no surface and present the result as complete. |
| `coder` | The mode-authoring skill. This project consumes a mode; it does not author one. Mode work happens in the `dsh-gstack` checkout, where the generator, the fragments and `gen.mjs --check` live. |
| `codex-cli-calling`, `grok-cli-calling`, `kimi-cli-calling`, `hermes-cli-calling` | Nothing in the four lanes shells out to another model CLI. The advisory path is `model_second_opinion` (§4), and the dispatch capability belongs to the harness, not to this project's method. |
| `dsh-badge` | It is for attributing *PRs*. This directory is not a git repository, `AGENTS.md` forbids `git init`/PRs unless asked, and the one upstream it consumes asks not to be contributed to. Revisit when the project's own repo is public and PRs exist. |
| `memory-consolidate` | Harness memory hygiene, not project work. It belongs to the profile that runs sessions, not to this mode. |

### 2.2 Near misses I deliberately keep

- **`gstack-careful` / `gstack-guard`** — a real fit, and the only catalog skill whose trigger
  ("touching prod, debugging live systems") describes the author's bench. `modprobe -r`,
  `bootc install to-disk /dev/nvme1n1`, `rm` on a results stick: warnings before all three are
  worth having. Name them in the persona; do not bundle a fourth copy of the lockout list.
- **`gstack-diagram`** — §5's four-artifact graph and R2-13's race are exactly the diagrams
  `ARCHITECTURE.md` needs. Narrow, cheap, real.
- **`gstack-context-save` / `gstack-context-restore`** — genuine value, with a defect to flag:
  their default state directory is `~/.gstack`, which `AGENTS.md` says is read-only on this
  machine. The persona must route state into the repo (the working rule already says so) or these
  two will fail at the moment they are most wanted.
- **`gstack-spec`** — the right way to turn the model rubric into a backlog item, but it files a
  GitHub issue and there is no remote yet. Available, blocked until `git init` and a remote.
- **`gstack-health`, `gstack-retro`, `gstack-learn`, `gstack-deslop-shared-libs`,
  `gstack-test-audit`, `gstack-make-pdf`, `gstack-freeze`, `gstack-setup-gbrain`,
  `gstack-sync-gbrain`, `gstack-upgrade`, `gstack-landing-report`** — harmless, off-task, no need
  to forbid them; just do not name them in the persona. (Excluding them explicitly would be
  prose that buys nothing, and the next revision of the catalog would make it stale.)

### 2.3 The project's own routing table now points at three wrong skills

`AGENTS.md` "Skill routing" is inherited boilerplate. Three lines are wrong for this project and
the mode's persona should supersede them:

- `QA / testing a running flow → /gstack-qa` — there is no browser or API flow; the runtime test is
  Tier 1/2.
- `Visual polish → /gstack-design-review` — no visual surface to polish.
- `Design system or plan with UI → /gstack-design-consultation` — the hub is one window with an
  inherited visual language; §7 does not ask for a system.

Two more need a caveat rather than a deletion: `Ship / deploy → /gstack-ship` is right for the tag
and wrong for the gate (Tier 2 decides), and `When in doubt, invoke the skill` is wrong for a model
claim, where doubt is answered by a run and never by a skill.

---

## 3. Bundled mode skills

**Decision: two bundled skills, not three.**

| Candidate | Call | Reason |
|---|---|---|
| 1. Verification ladder | **Keep** as `bluefin-t2-verification` | It encodes a *decision under pressure* — which tier a change may claim, and what is safe on the only working T2 Mac — that no static contract can carry without becoming a 1400-line document. |
| 2. Kernel-module packaging | **Merge into (1)**, as its build/sign/verify section | It is the candidate that most nearly restates §5 and §14 T1/T2, which already read as a checklist. What is *not* a restatement — which check proves which property, and the rule that the contributor's one-RPM loop is not evidence about the image artifact — is exactly a verification concern, so it belongs in the ladder. The mechanics (spec template, `KERNEL_SRC` divergence, dep order, `akmods --force` vs `rpmbuild`) stay where §10 P6 puts them: `ADD-A-MODULE.md`. |
| 3. T2 hardware bring-up | **Keep** as `bluefin-t2-hw-triage` | The only place the symptom→subsystem→implication reasoning can live. §4 supplies the expected sets as *data*; it does not say what a missing object implies, or which absence is a packaging bug and which is a correct no-device load. |

Why not a third: the obvious third is a `bluefin-t2-harness-tools` router, copying the Dakota
shape. It has almost nothing to route here — gbrain is off (§4), there is no browser, and the four
reference trees are grep-able shell and Rust. A skill whose only content is "read the file you are
about to change" is the waste the brief warns about. If a third slot is ever earned, it will be by
a real need appearing, not by symmetry with another mode.

### 3.1 `bluefin-t2-verification`

*What it encodes that `AGENTS.md` cannot:* the ordering and the permission — a Tier 0 green buys
nothing at Tier 2, a Tier 1 module load is not evidence about the image, and a tier that was not
run is named rather than implied. `AGENTS.md` carries two facts ("never unload the input modules",
"two kernels"); it cannot carry which command proves which property, what each tier's pass
criteria are, or what promotes a model from `unmeasured` to `validated`.

```
---
name: bluefin-t2-verification
description: Pick the narrowest tier that can actually fail a bluefin-t2 change, run it, and
  report only evidence observed — Tier 0 container conformance, Tier 1 safe live-module reload,
  Tier 2 hardware-in-the-loop to an external disk, Tier 3 kit/ISO, the rotation drill, and the
  module build/sign/verify loop. Use before claiming any change, model or release is good.
whenToUse: Use before reporting a build, module, model claim or release complete; when choosing
  the check for a Containerfile, spec, unit or report change; before touching the bench Mac.
metadata:
  verified-sources:
    - docs/designs/kait2en-bluefin-v2.md §9 (authoritative), §5, §13
    - AGENTS.md (the safe/unsafe module sets)
---
```

**Outline**

- **The rule before any command.** Never claim a higher tier than the one you ran. A blue build is
  a Tier 0 fact; a loaded module is a Tier 1 fact; a model claim needs Tier 2 for *that* model,
  digest-pinned. `untested` never becomes `working` because a similarly shaped machine passed.
- **Which tier for which change** (table): spec / kmod / signing → 0 + 1; Containerfile, kargs,
  units, `models.d`, `report` → 0; anything about a device actually working → 2; the ESP, the kit,
  the ISO, firmware crossing → 3; a key rotation → the drill, once per rotation, never folded into
  a release.
- **Tier 0, the harness image.** `akmods-t2:harness` (A1's build container, never a new image),
  the image's filesystem mounted read-only, one documented `podman run`. The load-bearing
  assertions, each with its exact failure string: the named 18-object set; `modinfo -F vermagic`
  equals `<kver>`; `depmod -a` clean; `modprobe --dry-run` proves order and existence only;
  `rpm -qpR` on all 12 RPMs contains `kernel-core-uname-r = <KVER>`; `extract-module-sig.pl` +
  `openssl cms -verify -certfile` per module; `lsinitrd` asserts **both** named lists (six
  installed-image, five installer); `systemd-analyze verify` on 15 + 3 units; `preset-all` dry-run
  plus the `*.wants` symlinks; SELinux at priority 400; `pam_fprintd.so` in both PAM files; the
  build-only set absent *and* no residue; the 13-name kargs diff; `models.d` schema and the
  18-objects-exactly-once check; `bootc container lint` last; delta ≤250 MB.
- **Tier 0's four negative tests are part of the ladder, not optional.** A missing kver tag must
  exit nonzero with the named error; a wrong-kver RPM must fail to install; deleting a
  `force_drivers` entry must fail at `lsinitrd`; `report` on fixture DMI must return 0/1/2. A
  positive-only run does not prove the guard exists.
- **The module loop (merged from the packaging candidate).** `just module <name> <kver>` builds,
  signs and verifies one `.ko`. The 12-module dependency order is real (`t2bce_dma → t2bce_core →
  t2bce_vhci`), `t2smc` uses `KERNEL_SRC` where the other eleven use `KDIR`/`KVER`, and there are
  three kernels in play (host, image, ISO). What this loop proves: one RPM for one kernel.
  What it does **not** prove: anything about the published artifact, which is `akmods --force`
  against the image's labelled kernel. Read `ADD-A-MODULE.md` for the mechanics; this section is
  the gate.
- **Tier 1, on the author's only working T2 Mac.** The safe set is four: `t2smc`,
  `t2thunderbolt`, `t2mfi_fastcharge`, `t2smp`. Never unload `t2hid`, `t2bce_*` or
  `hid_t2magicmouse` — that is the lockout, and it is a property of this machine, not a caution.
  Preconditions checked *before* the experiment: a second boot target or an external keyboard
  attached, and the rollback line written down (`modprobe <module>` from
  `/usr/lib/modules/$(uname -r)/updates/dkms/`). A module built on the Mac has the Mac's vermagic
  and will not match the image — expected, stated, not a failure. This tier is also where the
  packaged userspace is checked on real hardware: hwmon channels, the DSP profile, `fprintd-list`.
- **Tier 2, the only tier that proves a device.** Pinned invocation: `podman run --privileged
  --pid=host … quay.io/fedora/fedora-bootc:44 bootc install to-disk --source-imgref
  ghcr.io/<org>/bluefin-t2@sha256:<digest> /dev/nvme1n1`; the tested digest goes into
  `result.json`. Results live on the separate `K2B-HIL` stick, never on the disk being
  repartitioned. `attempt.json` is written by the host **before** power-on; the four-branch outcome
  table (pass/fail, `FAILED_USERSPACE` with the stage, `FAILED_BOOT` with a required photograph,
  `HARNESS_ERROR`) is evaluated by the host on the next run. The smoke set: the model's named
  objects from `models.d`, no `firmware load failed`, Wi-Fi associated, Touch Bar usable as the
  desktop user, `fprintd-list` non-empty, fingerprint offered at the lock screen,
  `systemctl --failed` empty, one suspend/resume cycle, `wpctl status` shows the DSP sink, then
  power off. Per release, never per daily build; a daily build that fails it is simply not
  offered.
- **Tier 3, gated.** One run per ISO build with the real kit and a real stick: ESP initramfs
  injection, GRUB rewrite, firmware capture and carry, a clean install with **no external hardware
  attached**, then — before first boot — the four firmware files, `SHA256SUMS` and
  `firmware-import.json` on the target ESP, then Wi-Fi associates. Negative runs: wrong-board
  payload refused, full target ESP fails with the named message, USB pulled mid-install fails at
  the payload copy and not after a reboot. Secure Boot states (b) and the deliberately-skipped (c)
  are produced here with the boot-menu rollback executed and recorded. Recovery contract, never
  negotiable: never install to the internal disk; Option-boot back to the previous deployment.
- **Reporting.** Quote the command, its exit code and the string it printed. Name the tier that
  ran and the tiers that did not. "CI is green" is not a hardware result, and "it should work" is
  not a result at all. If a check could not run, say which and why — a skipped tier reported as
  skipped is honest; a skipped tier omitted is the defect.
- **When a check fails.** Read the assertion before changing the artefact. A failing check usually
  states the invariant it enforces; loosening or deleting it converts a detected defect into an
  undetected one, and `lsinitrd` is the worked example — the build is the only place the keyboard
  guarantee is a proof.

### 3.2 `bluefin-t2-hw-triage`

*What it encodes that `AGENTS.md` cannot:* the inference from evidence to subsystem and from
subsystem to *fix or no-fix*, under a hard safety boundary. §4's `models.d` says what should be
loaded; it does not say what "present but not bound" means, which absence is a packaging bug, and
which is a correct no-device load. `AGENTS.md` names the forbidden modules; it does not give the
probe that distinguishes "the module never loaded" from "the module loaded and the firmware is
missing".

```
---
name: bluefin-t2-hw-triage
description: Diagnose which T2 subsystem is actually dead — keyboard, trackpad, Wi-Fi, Touch Bar,
  Touch ID, audio, fans/battery, Thunderbolt, suspend/resume — from uname, the image's
  ostree.linux label, modinfo vermagic, lsmod, dmesg/journalctl, lspci, the report JSON and the
  model's models.d file, and say what each failure implies. Read-only; no module is unloaded.
whenToUse: Use when something on a running T2 Mac stopped working, especially after a kernel
  bump or an upgrade; before proposing any module reload; after a Tier 1 or Tier 2 failure.
metadata:
  verified-sources:
    - docs/designs/kait2en-bluefin-v2.md §4 (expected sets), §6 R2-11, §7 (report), §9
    - AGENTS.md (the never-unload rule, the per-machine firmware)
---
```

**Outline**

- **Step 0 — is there a userspace at all?** No journal, no console, a black screen or a GRUB-only
  boot means this tree cannot help yet: the evidence path is the attempt marker plus a photograph
  (§6 R2-11), and the safe next action is the recovery contract (Option-boot, previous deployment,
  firmware from the stick). Say that instead of guessing. A T2 Mac has no serial console; the
  photograph is the capture, and it is a required field, not a habit.
- **Step 1 — settle the kernel identity before anything else.** `uname -r`, the image's
  `ostree.linux` label, and `modinfo -F vermagic <module>` must agree. The commonest cause of "the
  keyboard stopped after the kernel bump" is a module built against the host kernel and shipped
  for the image's, and no amount of reloading fixes a vermagic mismatch. This step costs three
  commands and rules out the largest single class of failure.
- **Step 2 — read the expectation, never recall it.** `cat /sys/devices/virtual/dmi/id/ProductName`,
  then `/usr/share/bluefin-t2/models.d/<ProductName>.toml`, then `bluefin-t2 report --json`. Three
  categories, and they mean different things: `expected_loaded`, `expected_unbound` (loaded, no
  device — e.g. `hid_t2magicmouse` with no Magic Mouse), `expected_absent` (in the image,
  correctly not loaded — e.g. `t2gmux` on a 13-inch). Anything outside the file is `untested`,
  never `broken`. Do not hardcode the 18 names; the TOML is the data and it is per-model.
- **Step 3 — classify before diagnosing.** Five states, five different owners:
  absent from the image → packaging (Tier 0 should have caught it); present, load fails → missing
  dependency, wrong vermagic, or a signature the kernel refuses; loaded, not bound → device
  absent, which is often correct; bound but the subsystem is dead → userspace, firmware or
  configuration, not the module; loaded with a `module_blacklist` hit → the kargs set, not the
  build. Naming the state narrows the fix before any experiment.
- **Step 4 — the per-subsystem map** (table, one row each): keyboard/trackpad (`lsmod` for
  `t2hid`/`t2bce_*`, `dmesg | grep -i t2`, the initramfs-vs-session split, the `module_blacklist`
  of `hid_apple`/`apple_bce`); Wi-Fi (`brcmfmac` asking for four per-machine files,
  `firmware load failed`, `/var/lib/firmware/brcm`, `firmware_class.path`, `iwevent`/`nmcli`);
  Touch Bar (the `t2bdrm` DRM node, `kait2en-touchbar-attach`, `t2touchbar_*`); Touch ID
  (`fprintd-list`, `pam_fprintd.so`, the bind unit); audio (`wpctl status`, the DMI-selected DSP
  profile, `alsaucm`, `t2bce_audio`/`t2smp`); suspend/resume (`mem_sleep_default=deep` in
  `/proc/cmdline`, the kernel's suspend/resume lines, `t2smc`); fans and battery (hwmon channels,
  `sensors`, the charge limit); Thunderbolt and ports.
- **Step 5 — safety before any experiment.** Never `modprobe -r` the input stack. A live test uses
  only `t2smc`, `t2thunderbolt`, `t2mfi_fastcharge`, `t2smp`, with a second boot target or an
  external keyboard, and the rollback command stated first. The recovery for a wrong turn is the
  boot menu and the previous deployment — not a reinstall, because Apple firmware still feeds GRUB
  its keyboard. Apple firmware never goes into the image: it is per-machine, read from the running
  macOS, and lands in `/var/lib/firmware`.
- **Step 6 — when the diagnosis is contested.** Take a `model_second_opinion` once a hypothesis
  exists; a decline is the decision, not a gap. Then close the loop the only way that counts: the
  Tier 1 or Tier 2 check that was failing now passes, or the change is not a fix.
- **Honest negatives.** No serial console. A pre-Linux failure is unobservable from inside the
  machine. A module that loads on the Mac against the Mac's kernel proves nothing about the image.
  Say which of these applies rather than reporting a pass the hardware did not give.

### 3.3 Mode shape (for whoever generates it)

Base on Coder, as ecommerce does, and:
`id: 'bluefin-t2'`, order 12 (Dakota 8, Coder 9, Creator Enhanced 10, ecommerce 11).
`overrides: ['row-skill-root.yml', 'row-plugin-manager.yml']` — the skill root because the bundle
ships two skills; the plugin-manager override is inherited from the Coder base and is *not* wanted
here (§4), so drop it from the recipe rather than copying ecommerce's list.
`additions: ['row-wyrmbrain-tools.yml', 'row-mcp-github-readonly.yml', 'mcp-rows.yml']` plus a
Playwright override that is off unless `GSTACK_MODE_BROWSER_MCP=1` (reuse
`row-mcp-playwright-optin.yml`; do not author a new fragment for a row the project does not want).
`skills: ['bluefin-t2-verification', 'bluefin-t2-hw-triage']`.
`mustMention`: the shipping name `bluefin-t2`, the two-kernel rule, the never-unload set, the
per-machine firmware rule, the no-PR-to-KaiT2en rule, and both skill names.

---

## 4. Row-set decision table

| Row | Verdict | Reason |
|---|---|---|
| `row-gbrain-tools.yml` | **No** | The typed code tools are TypeScript/TSX/JavaScript/Python only, and the four reference trees are shell, Rust, `.spec`, Containerfile and TOML — the graph cannot answer a question about them. The project's own source does not exist yet, and nothing is registered as a code source for this directory (which is not even a git repo), so `query`/`remember` would either fail or speak for another project's corpus. Revisit when there is real source to index — and even then, `code_*` will not cover the Rust apps. **Actively wrong for `remember`**: it writes to the cwd's source, and there is no cwd source to write to. |
| `row-wyrmbrain-tools.yml` | **Yes** | `model_second_opinion` is the arbitration path for exactly this project's hard calls — a suspend/resume diagnosis that will not reproduce, a rotation trade-off, a lockout risk. `model_route_status` explains a decline. Degrades safely to absent; costs tool surface only. |
| `row-mcp-github-readonly.yml` | **Yes — this one, not the shared row** | Four upstreams to read (`kaiT2en/KaiT2en-Fedora`, `ublue-os/bluefin`, `ublue-os/akmods`, `t2-atomic`) at pinned refs, and one prohibition that must be technical: never open a PR against `kaiT2en/KaiT2en-Fedora`. `X-MCP-Readonly: true` plus `X-MCP-Toolsets: context,repos,issues,pull_requests,actions` is the only control available, and it is deliberately narrower than the shared row. Taking the shared row would mount ten write tools in the same server that can reach the forbidden repository and leave prose as the only guard. Writes stay on `git`/`gh`, inside the approval path. |
| `row-plugin-manager.yml` | **No** | Nothing in the four lanes reads the profile's plugin inventory; that is mode-authoring work and it happens in the `dsh-gstack` checkout. It is the weakest possible yes and it costs surface in every session. (This is why the mode should not copy the Coder base's override wholesale.) |
| Playwright | **No** | No browser surface at all. **Actively wrong**: it makes "look at the installer screen" sound possible, and the black screen is pre-userspace. Keep the opt-in fragment only so the row exists off-by-default; never set `GSTACK_MODE_BROWSER_MCP`. |

Two notes on the rows:

- **The mode's differentiation is the two skills and the persona, not the row set.** The correct
  instinct on reading this table is that the mode adds almost no capability — which is right, and
  is the point of the exercise. Context7 stays (bootc, BuildStream-adjacent tooling, dnf5,
  systemd unit syntax), because a wrong unit directive is a Tier 0 failure with a confusing
  message.
- **The GitHub read-only row is the only place where "no" would be a policy failure rather than a
  preference.** The project's first non-negotiable is not editing `research/` and not contributing
  upstream; the row is the mechanism.

---

## 5. What this means for the next session

1. The mode is small on purpose: two skills, three rows (wyrmbrain, read-only GitHub, context7),
   one declaration that Playwright and gbrain are out.
2. `AGENTS.md`'s routing block is inherited and three of its lines point at skills this project
   should not invite (§2.3). The mode persona should supersede them; the file can stay as-is until
   the mode ships.
3. The two bundled skills are the only artefacts that must be written *before* T1, because the
   ladder is what T1's "one signed RPM" has to be checked against, and the triage tree is what the
   first bench failure will need. Their content points at the design (§4, §9) and at `models.d`
   data — it must not restate either.
