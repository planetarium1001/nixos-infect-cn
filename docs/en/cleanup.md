# Post-install cleanup

[中文](../zh-CN/cleanup.md) | English

`nixos-infect-cn` keeps the previous system intact in `/old-root`. This page explains when and how to remove those leftovers safely.  
Cleanup only touches install backups; it never changes NixOS itself.

## Why clean up

- `/old-root` is the complete root filesystem of the previous distribution and usually takes several GB of disk.
- `/boot.bak` is only created on EFI systems and is a backup of the old `/boot`.
- The old root still holds the previous system's `/root/.ssh`, application configuration, and logs, which is a leak risk if kept long term.
- With two sets of files side by side, paths are easy to misread while troubleshooting.

## Before you clean up

- You can already log in to NixOS with an SSH key, rather than only through the cloud console.
- DHCP or static networking, SSH, and your services all work, and you have rebooted successfully at least once; snapshot important data first.
- There is no rush: waiting a few days before deleting is fine, `/old-root` does not affect the running system.

## Run the cleanup script

```bash
bash /root/nixos-infect-cleanup.sh
```

The script runs a safety check first, then handles each item:

| Step | Behavior |
| --- | --- |
| Safety check | Requires `/run/current-system` to exist and `/etc/os-release` to contain `ID=nixos`, otherwise it refuses to run |
| `/old-root` | Asks `Remove /old-root? [y/N]`; only `y` / `yes` deletes it |
| `/boot.bak` | Deleted whenever present (EFI boot backup) |
| Garbage collection | Runs `nix-collect-garbage -d` |
| Self-removal | Deletes the script itself only when `/old-root` was deleted |

Example interaction:

```text
Old root filesystem detected at /old-root.
...
Remove /old-root? [y/N] y
Removing /old-root ...
Removing /boot.bak ...
Running nix-collect-garbage -d ...
Removing this script ...
=== Cleanup complete ===
```

- Pressing Enter, typing `n` / `no`, or any unrecognized input keeps `/old-root`.
- When it is kept, the script keeps itself as well, so you can re-run it later.
- `/boot.bak` is not asked about and is deleted whenever present; move it aside by hand first if you want to keep the boot backup.

## What happens if /old-root is kept

- The previous system files keep using disk space; nothing else is affected.
- The cleanup script will not delete it automatically and does not retry in the background.
- You can run `rm -rf /old-root` by hand at any time.
- After a manual delete, run the cleanup script once more so GC and self-removal complete.

## Manual cleanup

```bash
# Confirm you have booted into NixOS
grep '^ID=' /etc/os-release
ls -d /run/current-system

# Delete the old root and the EFI boot backup
rm -rf /old-root
rm -rf /boot.bak

# Collect old Nix generations
nix-collect-garbage -d

# Delete the script only after /old-root is gone
rm -f /root/nixos-infect-cleanup.sh
```

- Do not delete `/nix`: that is the Nix store, and the system will not boot without it.
- Do not delete `/etc/nixos`: that is the configuration currently in effect.
- `nix-collect-garbage -d` removes every old generation, and you cannot roll back to them afterwards.
- Before deleting by hand, make sure no data still needs to be recovered from `/old-root`.

## Verify after cleanup

```bash
df -h /
test ! -e /old-root && test ! -e /boot.bak && echo "cleaned up"
nixos-rebuild switch
```

- `df -h /` shows a clearly larger amount of free space.
- Only when `test ... && echo "cleaned up"` prints `cleaned up` is the system clean; no output means leftovers remain.
- `nixos-rebuild switch` completes normally, which means the configuration and channel are intact.
- Reboot once more and confirm you still reach NixOS and can log in over SSH.

## Related documentation

- [Quick start](./quickstart.md)
- [Troubleshooting guide](./troubleshooting.md)
- [How it works](./how-it-works.md)
