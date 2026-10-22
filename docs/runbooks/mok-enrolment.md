# MOK enrolment drill — rehearsing the Secure Boot step without trusting the throwaway key

This page is for the **bench/proof image**, whose modules are signed with the program's
throwaway proof key. It exists because enrolment is the one step that must happen *before*
the deployment whose modules need it (design R2-7): if the key is not enrolled when the new
kernel's modules are first loaded, they fail verification and — on a T2 Mac — the internal
keyboard never arrives.

**Read this first, because it is a security decision, not a checkbox.**

- The key in the image at `/etc/pki/akmods/certs/bluefin-t2.der` is the certificate for the
  **throwaway proof key** (`CN=bluefin-t2 THROWAWAY proof key - NOT PRODUCTION`, SHA-256
  fingerprint `55:0A:93:85:0E:F4:CC:DD:10:8E:DB:75:4F:AB:C0:47:AF:95:37:67:C7:FE:43:DF:BE:7D:13:22:5C:39:78:6C`).
- Its **private key sits in `akmods-t2/out/keys/signing.key` in this repository.** Anybody
  with that file can sign a kernel module your firmware will trust.
- So: enrolling it is a **drill**, and the drill ends with deleting it. Never enable Secure
  Boot while this key is enrolled unless you deliberately intend to trust this repo's
  throwaway key.
- Production enrolment is a Tier 3 / release step with the release key (human gate:
  signing, provenance, MOK).

## What the drill proves, and what it cannot

With Secure Boot **off** (this machine's current state, `mokutil --sb-state`):

- It proves the **plumbing**: `mokutil --import` writes the request, MokManager can be
  driven if shim invokes it, the key appears in the enrolled list, and the report/`mokutil`
  reads agree.
- It does **not** prove module loading under enforcement: with Secure Boot off, the kernel
  does not require the key at all. That requires Secure Boot on, which is a firmware
  setting (macOS Startup Security Utility on a T2 Mac) and a separate human decision.

If shim does **not** show MokManager with Secure Boot off, that is a real finding: the
enrolment path cannot be exercised in this configuration, and the real test needs Secure
Boot on.

## The drill (run it yourself; the agent has no sudo)

1. Confirm the current state and the file:

   ```
   mokutil --sb-state
   ls -l /etc/pki/akmods/certs/bluefin-t2.der
   openssl x509 -in /etc/pki/akmods/certs/bluefin-t2.der -inform DER -noout \
       -subject -fingerprint -sha256
   ```

2. Write the import request. `mokutil` asks for a one-time password; remember it for the
   next boot:

   ```
   sudo mokutil --import /etc/pki/akmods/certs/bluefin-t2.der
   mokutil --list-new          # the pending request, no reboot needed
   ```

3. Reboot. Two outcomes:

   - **MokManager appears** (blue screen, "Perform MOK management"): choose **Enroll MOK**
     → **View key** (check the fingerprint) → **Continue** → **Yes** → enter the one-time
     password → **Reboot**. Then continue at step 4.
   - **It does not appear** and the machine boots normally: the request stays pending.
     Record it as the finding and clear it at step 6.

4. Verify enrolment:

   ```
   mokutil --list-enrolled | grep -A2 -i 'bluefin'
   mokutil --sb-state                # still disabled — this is expected in the drill
   bluefin-t2 report                 # secure_boot is 'off', not 'on-enrolled'
   ```

5. Do not leave it enrolled. Delete the key:

   ```
   sudo mokutil --delete /etc/pki/akmods/certs/bluefin-t2.der
   sudo reboot
   ```

   MokManager appears again: **Delete MOK** → **Yes** → password → reboot.

6. Verify it is gone, or clear a pending request if MokManager never appeared:

   ```
   mokutil --list-enrolled     # empty
   # if a request is still pending and you do not want to reboot for it:
   sudo mokutil --revoke-import
   mokutil --list-new          # empty
   ```

## The rule for real installs

Enrol the **release** public key (the one shipped with the release image, published as a
release asset), not this throwaway. Order matters:

1. On the running system with a working keyboard, `mokutil --import` the release DER.
2. Reboot, complete MokManager.
3. Only then switch to / install the deployment whose modules need the key.

Doing it in the other order is what the design calls out in R2-7: the new deployment cannot
enrol anything for itself, and its keyboard may not arrive to let you try.

## Record

Fill this in when the drill is run, and paste it into the run's evidence:

```
date:
sb before:            SecureBoot disabled / enabled
request written:      yes/no   (mokutil --list-new output)
MokManager appeared:  yes/no
enrolled:             yes/no   (fingerprint)
report state:         off / on-enrolled / on-not-enrolled
deleted:              yes/no
sb after:
notes:
```
