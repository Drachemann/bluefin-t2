# Recovery — when the machine will not reach a usable desktop

This file ships at `/usr/share/bluefin-t2/RECOVERY.md`. Read it from another machine if
this one is the broken one: the image is on the installed disk, and the rules below are the
ones that matter before anything else.

## The one rule

**Never unload `t2hid`, `t2bce_*` or `hid_t2magicmouse` on a running T2 Mac.** They carry
the internal keyboard and trackpad. Unloading them locks you out of the machine you are
working on; recovery then needs an external USB keyboard. `t2smc`, `t2thunderbolt`,
`t2mfi_fastcharge` and `t2smp` are safe to reload — nothing else is.

## First: does it reach a login prompt on the internal keyboard?

- **Yes** → it is a userspace problem. Log in, run `bluefin-t2 report`, and read
  `journalctl -b -p err` plus `systemctl --failed`. Do not touch modules.
- **No keyboard, no trackpad, no display past the boot splash** → this is a boot-path
  problem, not a debugging session. Go to the next section.

## Boot-path recovery

1. **External USB keyboard and display.** On these machines the internal input is one
   module load away from working; an external keyboard is the cheapest way in. If the
   display is black but the machine is up, an external display over USB-C/HDMI may also
   work.
2. **Pick the previous deployment.** At the boot menu choose the previous entry, or from a
   working TTY run `bootc rollback` and reboot. The rollback is the supported path back to
   the last booting image; it does not reinstall.
3. **Recovery shell.** From the boot menu's rescue entry, or by adding
   `systemd.unit=rescue.target` to the kernel command line, get a root shell. Check
   `journalctl -b -1 -p err` and `dmesg | grep -i t2` for the failing subsystem. The
   modules, kargs and initramfs are image content; a missing `t2hid.ko` in the initramfs is
   a build defect, not something to fix on the machine.
4. **Firmware.** If Wi-Fi or Bluetooth is missing, the per-machine Apple firmware has not
   been imported. It lives in `/var/lib/firmware` and is selected by
   `firmware_class.path=`; it is never part of the image and cannot be published. Re-run
   `bluefin-t2-firmware-import` with the firmware copied from the machine's own macOS.
   `/var/lib/bluefin-t2/firmware.state` records whether an import happened.
5. **Touch Bar is black or the wrong row is showing.** Disable the userspace daemon:
   `systemctl --global disable kait2en-touchbar.service` and reboot. The attach unit checks
   that state and leaves Apple's firmware row in place instead of drawing a black panel.
   This is the documented escape hatch and it does not touch any module.
6. **Last resort: reinstall.** `bootc install to-disk` from the installer kit onto an
   external disk first, to confirm the image boots, before touching the internal disk.

## What to capture before rebooting

If the machine can still reach a shell, capture these to a USB stick — they are what a
Tier 2 failed-boot record needs:

```
journalctl -b -p err > /run/media/*/journal.txt
dmesg > /run/media/*/dmesg.txt
systemctl --failed > /run/media/*/failed.txt
bluefin-t2 report --json > /run/media/*/report.json
uname -r; rpm -q bluefin-t2 kmod-t2 2>/dev/null
```

The image identity (`ostree.linux`, the image digest) is the first thing to check against
the run's record: a module built for a different kernel fails with "invalid module format",
not a symbol error.
