# certs/ — the PUBLIC half of the throwaway proof key

Only public material is here. There is **no private key in this repository**, and there
must never be one.

| file | what |
|---|---|
| `t2-proof-THROWAWAY.pem` | public certificate, PEM (the `-certfile` used by the assertions) |
| `t2-proof-THROWAWAY.der` | same certificate, DER (the form shipped at `/etc/pki/akmods/certs/`) |

```
subject = CN=bluefin-t2 THROWAWAY proof key - NOT PRODUCTION, OU=throwaway, O=bluefin-t2-proof
serial  = 3813DEF486955F14D6BAF659A9A632DC7A7306FB
sha256  = FE:52:94:B4:B2:15:A6:94:7C:AD:C9:64:AD:77:A4:A2:AC:96:51:B8:09:BB:05:D5:CE:10:E9:88:1B:F2:BE:C2
valid   = 2026-10-20 .. 2026-11-19 (irrelevant: verification uses -noverify, as the kernel does)
```

This is the key that signed the 12 recorded RPMs in `record/MANIFEST.txt`. It exists so the
recorded artifacts can be verified later without the private key:

```sh
akmods-t2/scripts/verify-artifacts.sh akmods-t2/out/rpms 7.2.5-200.fc44.x86_64 \
    akmods-t2/certs/t2-proof-THROWAWAY.pem
```

## What this certificate is not

* **Not enrolled in MOK. Ever.** Enrolling it would teach the machine to trust a key whose
  private half was generated for one proof build.
* **Not a release key.** Releases are signed by an offline production key, used by CI on
  release tags, with its use gated on a human decision (design §5, closed call 2). The
  production public DER is a release asset; this file is not it.
* **Not a CA.** `openssl cms -verify -noverify` checks the signature against this
  certificate as the key, not a chain — which is the same shape as the kernel's
  `mod_verify_sig` against a MOK-enrolled key.

Rotation is additive and overlapping: a second key signs every module twice for at least
two releases (two `-signer` arguments in one CMS invocation), so a user on the old MOK entry
keeps a working keyboard through the overlap. This certificate predates that policy and was
never a rotation key.
