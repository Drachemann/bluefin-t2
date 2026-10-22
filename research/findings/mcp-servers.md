# MCP servers for `bluefin-t2` — which ones actually earn a row

**Status:** research finding. I installed nothing and touched no project file other than this
one. Every "works here" claim below was executed on this host and its output quoted.
Research date: 2026-10-20.

**Scope.** Which MCP servers would materially help an agent doing Linux system-level
engineering for `bluefin-t2` (kernel modules + signing, OCI/bootc image build, off-line image
audit, live T2 Mac diagnostics, Secure Boot). The bar is not "does it exist" but "does it earn
context in every session and a new failure surface at activation".

---

## 0. The host, measured

Claims about "runnable here" are relative to these observed facts, not to assumptions:

| Fact | Observed |
|---|---|
| OS / kernel | Fedora Linux 44, `7.2.11-200.fc44.x86_64` — read through `linux-mcp-server`'s `get_system_information` |
| Hardware | Intel `i5-1038NG7` — a 13-inch T2 MacBook Pro (this *is* a target machine) |
| `podman` | 5.8.9, rootless (`Rootless=true`), user socket **active** at `/run/user/1000/podman/podman.sock` |
| `skopeo` | 1.22.3; `skopeo inspect docker://ghcr.io/ublue-os/bluefin:stable` works and reports `ostree.linux = 7.2.5-200.fc44.x86_64` — the documented kernel gap, confirmed live |
| `bootc` | **absent** (as stated) |
| `codex` | **absent** |
| Homebrew | 7.0.10 at `/home/linuxbrew/.linuxbrew` |
| `mokutil`, `lspci`, `lsusb`, `lsmod`, `dmesg` | present |
| `journalctl` / `journalctl -k` | readable (user is in `wheel`) |
| `pmrep`, `pmlogger` (PCP) | **absent** |
| Docker Desktop / GUI | absent |
| Python | `uv` + `mise` (no `pipx`) |

---

## 1. Verdict table

| Candidate | Runnable here | Read-only | Tools (verified) | Recommend | Why |
|---|---|---|---|---|---|
| **rhel-lightspeed/linux-mcp-server** | **Yes** — installed 1.7.0, stdio verified, tools called | **Yes by default** (`toolset=FIXED`); `run_script` is opt-in and off | **23** | **Yes (narrow)** | The only candidate that returns *structured, filtered* journal/hardware/service data from the live T2 host. Real but modest win over `bash`. |
| **github/github-mcp-server** | Yes (already mounted in Coder mode) | Yes with `--read-only` | releases + Actions groups | **Defer** | Useful for release assets (public DER, ISO) and CI logs, but the repo does not exist yet and `gh` covers it today. |
| **mslacken/systemd-mcp** | Only after a **root** install (polkit policy + `gatekeeper` service) | Yes with `--allow-read` only (default is read) | **7** | **No / defer** | Genuine sd-bus access, but `make install` puts files in `/usr/bin`, `/usr/sbin` and installs a system service. Not worth that footprint for what `systemctl` already does. |
| **manusa/podman-mcp-server** | Yes (podman socket active; `npx` available) | **No** — mutations always exposed, no flag | **13** | **No** | No read-only mode and no per-tool gating (`container_remove`, `image_remove`, `image_push`, `container_run` always live). Also duplicates `bash` for the ~3 podman calls this project makes, and its fixed argument surface fights the custom build args the Containerfile needs. |
| **inspektor-gadget/ig-mcp-server** | No — wants Kubernetes + `kubeconfig` | Partial (`--read-only`) | 2 + ~30 dynamic `gadget_*` | **No** | Beta (`v0.0.1-beta.5`), cluster-shaped, and ~30 dynamically registered tools is a large permanent context tax for eBPF telemetry this project does not need. |
| **james116blue/journald-mcp-server** | Technically yes | Yes | **2** (`get_journal_entries`, `get_recent_logs`) | **No** | No `LICENSE` file at all, no releases, last commit 2025-12. Two tools that duplicate `journalctl`. |
| **sameehj/ebpf-mcp** | Yes, but needs `CAP_BPF`/`CAP_SYS_ADMIN` | **No** (`load_program`, `attach_program`) | **6** (`info`, `load_program`, `attach_program`, `inspect_state`, `stream_events`, `trace_errors`) | **No** | Loads/attaches eBPF into the running kernel — exactly the class of silent host mutation this project forbids — and is stale (2025-08). |
| **KyleCS0/linux-sysdiag-mcp** | Yes | Yes | incident-oriented (`find_incidents`, `get_context`, `cluster_events`, …) | **No** | No `LICENSE`, cluster/multi-server framing, and it reimplements journal parsing without adding anything over `journalctl`. |

---

## 2. The picks, in order

### 2.1 `linux-mcp-server` — the one that earns a row

Installed and working; see §3 for the full install/dependency story.

**Exact stdio row:**

```json
{
  "name": "linux",
  "type": "stdio",
  "command": "/home/linuxbrew/.linuxbrew/bin/linux-mcp-server",
  "args": ["--transport", "stdio", "--toolset", "FIXED"],
  "env": {
    "LINUX_MCP_HOST_MODE": "local-only",
    "LINUX_MCP_LOG_LEVEL": "ERROR"
  }
}
```

* `--toolset FIXED` is stated explicitly as defence in depth. `FIXED` is already the default,
  so this pins read-only behaviour even if a future release changes the default.
* `LINUX_MCP_HOST_MODE=local-only` confines every tool to this machine. The upstream default
  on Linux outside a container is `any`, which would also allow remote hosts.
* **Gotcha, found by triggering it:** the env var takes the *kebab* spelling — `local-only`.
  The CLI flag takes the *upper* spelling — `--host-mode LOCAL_ONLY`. Passing `LOCAL_ONLY` in
  the env var fails at import with `Input should be 'local-only', 'remote-only' or 'any'`.
* No `LINUX_MCP_USER`, no SSH key, no `LINUX_MCP_HOST` is needed: local stdio mode does not go
  through SSH. The Homebrew caveats' SSH guidance applies only to the goose/remote workflow.
* `LINUX_MCP_LOG_LEVEL=ERROR` keeps the server's own chatter down. It writes logs to files by
  default; `LINUX_MCP_LOG_OUTPUT=stdout` must only be used with HTTP transports.
* The binary emits an `AuthlibDeprecationWarning` on **stderr** at startup — harmless, and it
  does not corrupt the stdio JSON-RPC channel.

**Exact tool names exposed (23, all `readOnlyHint: true`), read from the live registry via
`tools/list` — not from a README:**

```
get_cpu_information        get_disk_usage            get_hardware_information
get_journal_logs           get_listening_ports       get_memory_information
get_network_connections    get_network_interfaces    get_process_info
get_service_logs           get_service_status        get_system_information
list_block_devices         list_directories          list_files
list_processes             list_services             pcp_guide
pcp_list_metrics           pcp_performance_summary   pcp_query_metrics
read_file                  read_log_file
```

**What it actually covers, and what it does not.** This matters for a project whose real work
is kernel modules:

| Project need | Covered? |
|---|---|
| `systemctl` (list units, status, unit journal) | Yes — `list_services`, `get_service_status`, `get_service_logs` |
| `journalctl`, **including `dmesg`/kernel ring buffer** | Yes — `get_journal_logs` with `transport: "kernel"` |
| `lspci`, `lsusb`, `lscpu` | Yes — `get_hardware_information` returns exactly `lscpu`, `lspci`, `lsusb` |
| kernel version, OS, uptime | Yes — `get_system_information` |
| **`lsmod`, `modinfo`, `modprobe`, `depmod`, `vermagic`, `dkms`** | **No** — no module tool at all |
| **`sign-file` / `openssl cms` / `mokutil` / `sbverify`** | **No** |
| **`lsinitrd`, `systemctl --root=`, `rpm -qpR`, `udevadm verify`** | **No** |
| **`podman` / `skopeo` / `bootc` / `cosign`** | **No** |

So it helps the **live-diagnostics** half (design §9 Tier 1/2) and does nothing for the kernel
or image half (Tier 0/3). Both halves still need `bash`.

**Evidence it works, and is on-topic.** `get_journal_logs({"transport":"kernel","last_lines":3})`
against this host returned live T2 input-driver errors:

```json
{"entries":["Oct 20 20:23:42 xiuhcoatl kernel: t2magicmouse 0003:05AC:0265.0033: unable to request touch data (-32)", ...],
 "unit":null,"path":null,"lines_count":3}
```

That is the exact hardware layer this project exists to port, returned as bounded structured
JSON rather than a raw journal dump.

**The honest case for the row — and the anti-case.** The benefit is **context efficiency and
shape**: bounded line counts, unit/priority/time filters, and JSON instead of a 4,000-line
`journalctl` paste. The benefit is *not* safety. Adding a read-only MCP row does **not** reduce
blast radius here, because the same agent has an unrestricted `bash` and can `sudo` anything
the MCP server refuses. Anyone who adds this row believing it guards the kernel or the disks
has misunderstood it. If the project's mode will mostly do Tier 0 container conformance (no
live host), this row is not worth its schema cost at all — gate it on live-host work.

**Cost notes.** 23 tool schemas in every session. Four of them (`pcp_*`) are **inert on this
host**: `pmrep` and `pmlogger` are not installed, and `get_system_information` reports
`"pcp":{"installed":false,"missing_commands":["pmrep","pmlogger"]}`. Treat it as a 19-tool
server in practice. If the row's cost ever needs trimming, the PCP tools are the first to go.

---

### 2.2 `github/github-mcp-server` — defer, and pin `--read-only` when it lands

MIT licensed, latest release `v2.0.2` (2026-10-08). Already mounted in Coder mode, so it is
not a new cost there; it is only worth a *project* row once the repository exists and CI
publishes artifacts.

**Exact stdio row:**

```json
{
  "name": "github",
  "type": "stdio",
  "command": "github-mcp-server",
  "args": ["stdio", "--read-only", "--toolsets", "repos,actions"],
  "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PAT}" }
}
```

**Relevant tool names (release + Actions groups, confirmed in source):**

```
list_releases           get_latest_release    get_release_by_tag
list_workflows          get_workflow          list_workflow_runs
get_workflow_run        get_workflow_run_logs list_workflow_jobs
get_workflow_job_logs   list_workflow_run_artifacts
download_workflow_run_artifact                get_workflow_run_usage
```

Why defer rather than yes: the design needs this capability eventually — the public DER is a
release asset for `mokutil --import`, and CI is the only place releases are signed (§5 signing
lifecycle). But there is no git repo yet, so there are no runs or releases to read, and `gh`
in `bash` covers the same ground. `--read-only` is mandatory when it is added: the write tools
(`merge_pull_request`, `push_files`, `create_or_update_file`, …) run in the MCP process,
outside this harness's approval path.

---

### 2.3 `systemd-mcp` — no (the best of the rejected, and why it still loses)

MIT, version `0.3.5` (from the repo's `VERSION` file; **no git tags or GitHub releases exist**,
so "last release" is undefined). Genuinely interesting: it talks sd-bus directly rather than
shelling out to `systemctl`, and it is write-gated.

**The row it would need:**

```json
{
  "name": "systemd",
  "type": "stdio",
  "command": "/usr/bin/systemd-mcp",
  "args": ["--allow-read"],
  "env": {}
}
```

**Tools (7):** `list_loaded_units`, `list_unit_files`, `change_unit_state`,
`check_restart_reload`, `list_log`, `get_file`, `get_man_page`. Write is gated by
`--allow-write` (absent above), and `--enabled-tools` can allowlist.

It loses on footprint, not on quality. There is no bottle or release — you build it with Go and
`make install`, which writes `/usr/bin/systemd-mcp`, `/usr/sbin/gatekeeper`, two systemd units,
and a polkit policy. For a project whose whole premise is *not* mutating the host, permanently
installing a root-adjacent service to read unit state that `systemctl status` already prints is
a bad trade. Revisit only if unit-state queries become frequent enough that structured output
pays for the install.

---

## 3. `linux-mcp-server` specifically

### 3.1 Install state — the contradiction, resolved

The brief said the owner believes it is installed and Homebrew says it is not. **Both were
true, ten minutes apart.** It is **now installed**:

```
$ brew info linux-mcp-server
==> ublue-os/tap/linux-mcp-server: stable 1.7.0 (bottled)
Installed (on request)
License: GPL-3.0-only
==> Installed Versions
ublue-os/tap/linux-mcp-server 1.7.0 (3,899 files, 51.9MB) [Linked]
==> Dependencies
Required (6): block-goose-cli, gemini-cli, libffi, libyaml, openssl@3, python@3.12
Recursive Runtime (52): all installed ✔
```

My **first** `brew info` in this session reported `Not installed`, and `which linux-mcp-server`
failed. File mtimes show why: `goose` was linked at 20:12, `gemini` at 20:17, and
`linux-mcp-server`'s keg at **20:19** — the install was *in flight* while I was probing, so the
early read was accurate at the time and is stale now. The bottle had already been fetched
(`~/.cache/Homebrew/linux-mcp-server--1.7.0.x86_64_linux.bottle.tar.gz`).

**Consequence for the earlier belief:** the owner's memory was right, not wrong — the binary
now resolves at `/home/linuxbrew/.linuxbrew/bin/linux-mcp-server` and prints `1.7.0`. There is
no `~/.config/goose/config.yaml`, so `goose-mcp-setup` was never run.

Verified end to end: `--version` → `1.7.0`; a stdio `initialize` handshake succeeds; `tools/list`
returns 23 read-only tools; `get_system_information` and `get_journal_logs` return real host data.

### 3.2 The dependency situation

**The two CLI dependencies are real, mandatory to `brew install`, and unnecessary at runtime.**

* They are hard `depends_on` lines in the formula — `block-goose-cli` and `gemini-cli` are
  unconditional runtime dependencies, not optional extras.
* They exist for **someone else's client**, not for the server. The formula's `install` block
  writes a `goose-mcp-setup` script whose body writes a goose config containing
  `GOOSE_PROVIDER: gemini-cli` and `GOOSE_MODEL: gemini-3-flash-preview`, pointing goose at
  this server over stdio. Neither `goose` nor `gemini` is imported by the server.
* **The Python package proves it.** Runtime dependencies are `asyncssh[bcrypt]`, `fastmcp`,
  `httpx`, `pydantic`, `pydantic-settings`, `fakeredis`. No goose, no gemini. The console script
  is `linux-mcp-server = linux_mcp_server.__main__:cli`, so `uvx linux-mcp-server` or
  `uv tool install linux-mcp-server` yields the identical server with **no AI CLI at all**.
* **The cost of the brew route, measured:** `linux-mcp-server` 75 MB + `gemini-cli` 99 MB +
  `block-goose-cli` 328 MB ≈ **502 MB** and 52 recursive runtime formulae, of which ~427 MB is
  two AI CLIs this project will never invoke.
* `gemini-cli` is *not* a runtime requirement of the gatekeeper path either — the gatekeeper is
  provider-agnostic (OpenAI, Anthropic, Gemini, OpenRouter, Vertex AI) and is **only** required
  when the toolset is not `FIXED`.

**Was there a cleaner path?** Yes, and it still exists for a second machine or a rebuild:
`uv tool install linux-mcp-server` (or an `uvx` row) gets the same 23 tools with 5 Python
dependencies. On *this* machine the 502 MB is already spent, so churning the install buys
nothing except disk. Do not reinstall to "fix" it.

### 3.3 Read-only, honestly

Structurally read-only as configured, and that is a real property, not marketing:

* `toolset` defaults to `FIXED`. The 23 registered tools are all annotated `readOnlyHint: true`,
  and **no** script-execution tool appears in `tools/list`.
* The arbitrary-code-execution path (`run_script`, `validate_script`, `execute_script`, …) is a
  *separate* toolset. It is unticked unless you pass `--toolset RUN_SCRIPT`/`BOTH`, and doing so
  makes the process **refuse to start** without a gatekeeper provider and model:
  `gatekeeper.provider ... and gatekeeper.model ... must be set when toolset is 'run_script'`.
  That gatekeeper is itself an LLM call, so enabling script execution pulls in a provider
  credential and a second model in the loop.
* Residual risk is therefore low, but note `read_file`/`read_log_file`/`list_files` can read any
  file the user can read (`~/.ssh/id_ed25519`, the organisation signing key if it is ever staged
  locally). Scope log reads with `LINUX_MCP_ALLOWED_LOG_PATHS` where that matters; there is no
  equivalent allowlist
  for `read_file` in the row above.

### 3.4 Licensing

Upstream is **inconsistent**: the repo's `LICENSE` is **Apache-2.0**, the repo also ships
`licenses/GPL-3.0.txt`, and the built distribution metadata declares **GPL-3.0-only** — which
is what Homebrew reports. Treat it as GPL-3.0-only. That is acceptable here only because this
is a **developer tool that is never redistributed inside the image**; it must not be added to
`bluefin-t2`'s runtime set.

### 3.5 Recommendation

**Keep it installed. Wire it into the project's agent mode as a single stdio row, exactly as in
§2.1 — but only when the mode is doing live-host work, and with no expectation that it makes
the agent safer.**

Do:
1. Add the row from §2.1, with `--toolset FIXED` and `LINUX_MCP_HOST_MODE=local-only`.
2. Never run `goose-mcp-setup` — it writes a goose config this project does not want.
3. Keep the kernel/image half on `bash`; there is no module, image or signing tool here.

Do not:
1. Do not enable `--toolset RUN_SCRIPT`/`BOTH`. That turns a read-only diagnostics server into
   arbitrary host execution behind an LLM gatekeeper, which is the one thing this project's
   invariants forbid.
2. Do not expect `lsmod`/`modinfo`/`sign-file`/`lsinitrd`/`skopeo`/`cosign` coverage. It has none.
3. Do not reinstall via brew on a fresh machine without weighing 502 MB for a 23-tool reader;
   `uv tool install linux-mcp-server` is the lean equivalent.

---

## 4. Rejected candidates, so nobody re-researches them

| Candidate | Reason rejected |
|---|---|
| **manusa/podman-mcp-server** | Apache-2.0, `v0.0.15` (2026-02-27, i.e. ~8 months stale at `0.0.x`). 13 tools — `container_inspect`, `container_list`, `container_logs`, `container_remove`, `container_run`, `container_stop`, `image_build`, `image_list`, `image_pull`, `image_push`, `image_remove`, `network_list`, `volume_list`. **No read-only mode and no per-tool gating**; the only flags are `--port`, `--output-format`, `--podman-impl`. Its `image_build` takes an absolute Containerfile path and a tag, which cannot express the custom `--label`/`--karg`/build-arg surface the `bluefin-t2` Containerfile needs, so `podman build` in `bash` wins anyway. |
| **containers/podman-mcp-server** | **Does not exist** — `https://github.com/containers/podman-mcp-server` returns HTTP **404**. The real project is `manusa/podman-mcp-server`. Do not cite the `containers/` org. |
| **inspektor-gadget/ig-mcp-server** | Apache-2.0, `v0.0.1-beta.5` (2026-05-18). Fixed tools `ig_deploy`, `ig_gadgets`, plus ~30 dynamically registered `gadget_*` tools (`gadget_trace_tcp`, `gadget_top_file`, …). Requires Kubernetes + `kubeconfig` + Docker; the upstream README itself warns the tool count eats context. Wrong shape for a single laptop and a permanent schema tax. |
| **sameehj/ebpf-mcp** | Apache-2.0, last commit 2025-08 — stale. 6 tools incl. `load_program` and `attach_program`, which mutate the running kernel and need `CAP_BPF`/`CAP_SYS_ADMIN`. Directly conflicts with "never silently mutate the host's kernel". |
| **james116blue/journald-mcp-server** | **No `LICENSE` file.** No releases; last commit 2025-12. 2 tools (`get_journal_entries`, `get_recent_logs`) that are a thin wrapper over `journalctl`, which `linux-mcp-server`'s `get_journal_logs` already covers with richer filters. |
| **KyleCS0/linux-sysdiag-mcp** | **No `LICENSE` file.** Last commit 2026-04. Incident/cluster-oriented (`find_incidents`, `get_context`, `cluster_events`, `connect`); assumes multi-server clusters and reimplements journal parsing for no gain here. |
| **stacklok/dockyard, IBM/mcp-context-forge cosign plugin, hyper-mcp** | Surfaced by search but are not answers to this question: `dockyard` packages/signs *MCP servers* as OCI artifacts, `mcp-context-forge`'s cosign work verifies *MCP servers* before deployment, and `hyper-mcp` is a WASM plugin host that needs `cosign` for plugin loading. None inspects **this project's** image or verifies **its** module signatures. |

### 4.1 Categories where nothing exists (searched, not invented)

* **No MCP server for `skopeo` / `cosign` / `sigstore` as an image-inspection tool.** Searches
  return MCP-*packaging* projects that use cosign on themselves, and the `skopeo-inspect(1)` man
  page — not a server. `bash` + `skopeo` + `cosign` is the answer.
* **No MCP server for `bootc`**, and no ublue/bootc-specific server. Irrelevant in practice:
  `bootc` is absent from this host and is used from inside a container.
* **No kernel-module MCP server** — nothing exposes `modinfo`, `vermagic`, `depmod`, `dkms`, or
  module signing. This is the project's single largest work area and every MCP candidate is
  silent on it. A `sign-file`/`modinfo` server does not exist to recommend; do not hunt further.

---

## 5. Summary judgement

Adding MCP servers does not solve this project's problem, because the work is *deterministic
CLI system engineering* — `make`, `openssl cms`, `scripts/sign-file`, `podman build`, `skopeo`,
`lsinitrd`, `rpm -qpR`, `mokutil`. Almost every candidate is a wrapper that would have to be
fought to pass the exact flags these steps need, and each one taxes every session with its tool
schemas.

One server clears the bar, narrowly: **`linux-mcp-server`**, for bounded structured reads of the
journal (including the kernel ring buffer), unit state and PCI/USB inventory on a live T2 Mac.
One defers: **`github-mcp-server`**, with `--read-only`, once there is a repository and CI
releases. Everything else is noise here, and the two most tempting alternatives are the two
worst: `podman-mcp-server` mutates by default, and `ebpf-mcp` loads into the live kernel.

---

## Sources

* linux-mcp-server repo and tool registry: <https://github.com/rhel-lightspeed/linux-mcp-server>
  (`src/linux_mcp_server/tools/__init__.py`, `config.py`, `server.json`; tools enumerated live
  over stdio on this host)
* Homebrew formula (the two `depends_on` lines, `goose-mcp-setup` body, GPL-3.0-only):
  <https://github.com/ublue-os/homebrew-tap/blob/HEAD/Formula/linux-mcp-server.rb>
* Upstream docs: <https://rhel-lightspeed.github.io/linux-mcp-server/clients/>
* podman-mcp-server: <https://github.com/manusa/podman-mcp-server> ·
  <https://pypi.org/project/podman-mcp-server/>
* systemd-mcp: <https://github.com/mslacken/systemd-mcp>
* ig-mcp-server: <https://github.com/inspektor-gadget/ig-mcp-server> ·
  <https://pkg.go.dev/github.com/inspektor-gadget/ig-mcp-server>
* ebpf-mcp: <https://github.com/sameehj/ebpf-mcp>
* journald-mcp-server: <https://pypi.org/project/journald-mcp-server/>
* linux-sysdiag-mcp: <https://github.com/KyleCS0/linux-sysdiag-mcp>
* github-mcp-server (read-only mode, toolsets): <https://github.com/github/github-mcp-server>
* Bluefin's own troubleshooting guidance recommending the tap install:
  <https://github.com/ublue-os/bluefin/discussions/4194>
