# Model support — what bluefin-t2 claims, and what it does not

This file ships at `/usr/share/bluefin-t2/MODELS.md` and is generated from the same record
the report reads: `/usr/share/bluefin-t2/models.d/<model>.toml`. If the two disagree, the
`.toml` files are authoritative and this page is stale.

## The claim rule

A model is **supported** only when a digest-pinned Tier 2 run (the real image, installed
and booted on that model) has been recorded for it. Generic code that happens to be shared
with a validated model is not evidence. This is the one claim the project cannot recover
from if it is overstated, so the report prints a per-model verdict, never a global "works"
badge.

## The four models

| Model | Status | What the status means |
|---|---|---|
| `MacBookPro16,2` | **validated** | A digest-pinned Tier 2 run was recorded on this model. The measured split in `MacBookPro16,2.toml` says which subsystems worked, which are unmeasured, and which did not. |
| `MacBookPro15,2` | **validation-set** | In the design's device class and expected to work, but no Tier 2 run has been recorded for it. Its measured states are `unmeasured`; the report prints `untested`, not `working`. |
| `MacBookPro15,4` | **validation-set** | Same as `15,2`. |
| `MacBookPro16,3` | **argument** | Included by written argument from the shared hardware, not by any run. The weakest status the project allows and it is labelled as such. |

## What would promote a model

1. Build the release image from a pinned digest.
2. Install it with `bootc install to-disk` to an **external** disk on that model.
3. Boot it, run the Tier 2 smoke test, and record the runbook sections.
4. Update `models.d/<model>.toml`: `status`, then each measured state with the evidence
   from that run.

Until all four steps exist for a model, it stays at `validation-set` or `argument`. Editing
the status without the run is the overclaim the rule above forbids.

## Which subsystems each file describes

`kernel`, `secure_boot`, `firmware`, `modules` and `notes` follow the same shape for every
model. The measured split (`working` / `untested` / `broken`) is only populated for a model
that has a run; on the others it is empty by construction, and the report renders empty as
`untested` rather than guessing.

Run `bluefin-t2 report` on the machine to see this model's verdict, or
`bluefin-t2 report --json` for the machine-readable contract (`docs/report-schema.md`).
