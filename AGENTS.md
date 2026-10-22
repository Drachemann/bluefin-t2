# AGENTS.md — KaiT2en-Bluefin

Project contract for coding agents working in this repository.

## What this project is

An immutable-OS port of KAIT2EN's T2 Mac support onto Bluefin Classic (Fedora 44,
`ghcr.io/ublue-os/bluefin`). Greenfield: the design is approved, no build code exists yet.

- Design of record: `docs/designs/kait2en-bluefin-v2.md` — read this first. v1
  (`docs/designs/kait2en-bluefin.md`) and the four reviews in `docs/reviews/` are the record
  behind it; v2 supersedes v1 wherever they differ.
- Evidence base: `research/findings/kait2en.md`, `research/findings/bluefin.md`,
  `research/findings/t2atomic.md`.
- Source trees are shallow clones under `research/` (`KaiT2en-Fedora`, `bluefin`, `akmods`,
  `t2-atomic`). They are read-only reference material; never edit them.

## Facts that will bite you

- **Two different kernels.** A fully-updated Fedora 44 host runs `7.2.11-200.fc44.x86_64`;
  `bluefin:stable` labels `ostree.linux = 7.2.5-200.fc44.x86_64`. Modules do not load across
  that gap. Build for the image's label, not `uname -r`.
- **Never unload the input modules.** `t2hid`, `t2bce_*` and `hid_t2magicmouse` carry the
  internal keyboard and trackpad. Unloading them on a T2 Mac locks the machine out.
  `t2smc`, `t2thunderbolt`, `t2mfi_fastcharge` and `t2smp` are safe to reload.
- **Apple firmware cannot be published.** It is per-machine, read from the running macOS at
  `/usr/share/firmware/wifi/`, and KAIT2EN refuses the redistribution packages. It goes in
  `/var/lib/firmware` with `firmware_class.path=`, never in the image.
- **The install medium is the hard part.** t2-atomic's documented limitation — external
  keyboard, mouse and ethernet — is exactly what the macOS kit exists to remove.
- `bootc` is not installed on the host; use `quay.io/fedora/fedora-bootc:44` in a container.
  `podman` and `skopeo` are present.

## Working rules

- `~/.gstack` is read-only on this machine; write state into the repo instead.
- This directory is **not a git repository yet**. Do not run `git init`, commit, push or open
  a PR unless asked in the session.
- Do not open PRs against `kaiT2en/KaiT2en-Fedora`: its `README.md` says it rejects
  AI-authored contributions and asks to be contacted in person. Consume it as a pinned
  submodule.
- The shipping name is `bluefin-t2`, not `KaiT2en-Bluefin` — see `TRADEMARK.md` in the
  KAIT2EN tree for why.

## Skill routing

The **Bluefin T2** agent mode (`bluefin-t2`) carries this project's routing in its persona, and
that persona is authoritative where the two differ. Work in this project in that mode.

When the user's request matches an available skill, invoke it. When in doubt about a *fault*,
invoke the skill; when in doubt about a *hardware claim*, a run is the answer and no skill can
supply one.

- Kernel module stopped loading / a subsystem is dead → `bluefin-t2-hw-triage` for evidence,
  then `/gstack-investigate`
- Which check proves this / is this change done → `bluefin-t2-verification`
- A build failing with one of this project's own named errors → **no skill**; that guard is a
  safety property and "fixing" it deletes the guard
- Reviewing a `Containerfile`, kit script or spec change → `/gstack-review`
- Adding a model to the supported set → **no skill**; only a digest-pinned Tier 2 run promotes it
- Architecture / locking a plan → `/gstack-plan-eng-review`
- Strategy / scope / "is this ambitious enough" → `/gstack-plan-ceo-review`
- User-facing documentation → `/gstack-document-generate`
- Signing keys, MOK, provenance, registry policy → `/gstack-cso`
- Ship a release → `/gstack-ship`
- Save / resume progress → `/gstack-context-save`, `/gstack-context-restore`
- Backlog-ready spec or issue → `/gstack-spec`

Do not invite: `gstack-qa`, `gstack-qa-only`, `gstack-browse`, `gstack-design-*`,
`gstack-devex-review`, `gstack-benchmark`, `gstack-canary`, `gstack-ios-*`. This project has no
browser flow, no web UI, no iOS app, no deployed service and no marketing site — a browser
pointed at a black screen that appears before userspace starts is a wasted cycle.

`gstack-context-save` and `gstack-context-restore` default to `~/.gstack`, which is read-only on
this machine. Point them at a repo-local state directory, or they will fail.

## Name

The distribution, the repository and the agent mode are all **`bluefin-t2`**. KAIT2EN's
`TRADEMARK.md` grants factual reference ("includes KAIT2EN's T2 support") but requires
permission to use its name for a fork, distribution, product or service — so `KaiT2en-Bluefin`
is a working description, never a ship name. New surfaces take `bluefin-t2-*`; inherited
KAIT2EN binaries and units keep their names so the pinned submodule stays reviewable against
upstream. Renaming the distribution is a human decision.
