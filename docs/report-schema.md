# `bluefin-t2 report --json` — the schema, version 1

This is the contract between three consumers, and it is deliberately small: the hub's
Overview and the Tier 2 smoke test read the same document, so every assertion exists once.

* `bluefin-t2 report --json` — the CLI (design §7, T10)
* the hub, which renders `report --json` and never the human format (§7)
* the HIL smoke test, which links the same checks into `result.json`

Exit codes are part of the contract:

| Exit | `verdict` | Meaning |
|---|---|---|
| 0 | `ok` | supported model, every required check passes |
| 1 | `not-ok` | supported model, something required is missing or failed |
| 2 | `unsupported` | the model is not in the supported set — a soft verdict, never a refusal |

A model is **supported** when `/usr/share/bluefin-t2/models.d/<product_name>.toml` exists.
Its `status` is the evidence tier: `validated` (a digest-pinned Tier 2 run is recorded),
`validation-set` (claim pending its own run), or `argument` (supported by the written
argument). Nothing else is a supported model.

## Document

```json
{
  "schema": 1,
  "tool": "bluefin-t2",
  "version": "0.1.0",
  "verdict": "ok | not-ok | unsupported",
  "exit_code": 0,
  "product_name": "MacBookPro16,2",
  "model": {"class": "validated | validation-set | argument | unknown", "file": "/usr/share/bluefin-t2/models.d/MacBookPro16,2.toml"},
  "system": {"kernel": "7.2.5-200.fc44.x86_64", "image": "44.20261013"},
  "secure_boot": {"state": "on-enrolled | on-not-enrolled | on-unknown | off | unknown"},
  "modules": {
    "present": ["t2bce_dma", "…"],
    "missing": [],
    "unexpected": [],
    "unbound": ["hid_t2magicmouse"],
    "unmeasured": []
  },
  "firmware": {"state": "imported | absent | unknown", "detail": "payload sha256 or empty"},
  "failed_units": ["unit.service"],
  "problems": ["module(s) not loaded: t2smc"],
  "warnings": ["untested on this model: hid_t2magicmouse, t2gmux"]
}
```

Field rules:

* `schema` is the integer version of this document; a breaking change bumps it.
* `model.file` is `null` when the model is unsupported.
* `modules.*` are the four categories of the model file, resolved against `/sys/module`:
  `present` and `missing` from `expected_loaded`, `unbound` from `expected_unbound`
  (loaded is the only requirement), `unexpected` from `expected_absent` (loaded at all is
  a failure), `unmeasured` is informational and never a pass or a failure.
* `secure_boot.state` is `unknown` when the state cannot be read, and `on-unknown` when
  Secure Boot is on but `/etc/pki/akmods/certs/bluefin-t2.der` is absent.
* `failed_units` is `null` when the check could not run (`--root` fixture mode), `[]` when
  it ran and found none.
* `problems` are the reasons for exit 1; `warnings` never change the exit code.
* **There is no timestamp and no hostname.** The document is deterministic for a given
  machine state, which is what makes it testable; the bug report adds the human context.

## Fixtures

`--root DIR` reads facts under `DIR` instead of `/` (`sys/`, `proc/`, `usr/share/bluefin-t2/`,
`var/lib/bluefin-t2/`, `etc/os-release`) and never executes `mokutil`, `systemctl` or
`uname`. That is how Tier 0 exercises the exit codes without a T2 machine or a booted
system: a fixture tree with the model file, the module directories and the firmware state.
