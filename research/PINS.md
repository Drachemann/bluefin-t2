# Reference clones — read-only, pinned

These four upstream trees are consumed by the build (`build.sh` stages
`research/KaiT2en-Fedora` into the image context; `akmods-t2` uses the kernel/RPM
references). They are **not committed**: they are large, they are upstream history we do not
own, and `kaiT2en/KaiT2en-Fedora` explicitly rejects AI-authored contributions. Treat them
as pinned submodules without the submodule plumbing.

| Path | Upstream | Commit |
|---|---|---|
| `research/KaiT2en-Fedora` | https://github.com/kaiT2en/KaiT2en-Fedora.git | `ba9d2d830ae5b4ccacf7f82ccc305270496397ff` |
| `research/bluefin` | https://github.com/ublue-os/bluefin.git | `13efd26e908c1dc956a731baf365966a8d5e57a3` |
| `research/akmods` | https://github.com/ublue-os/akmods.git | `d3958bd6c1a8301d74d46e3b1ed6d9164a434d2d` |
| `research/t2-atomic` | https://github.com/kansei-os/t2-atomic.git | `d8b3ee7d54664b018ba4416708e04f314acf0bb9` |

Materialise them with:

```sh
research/fetch.sh
```

Rules, from `AGENTS.md`:

- read-only: never edit, never commit a change inside them;
- **never** open an issue, PR, fork, dispatch or comment against `kaiT2en/KaiT2en-Fedora`;
- the clones are shallow, so history questions have no answer there;
- a re-pin is a deliberate change to this table plus a `research/fetch.sh` run, not a
  `git pull`.
