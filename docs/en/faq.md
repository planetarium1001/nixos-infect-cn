# FAQ

[中文](../zh-CN/faq.md) | English

Answers to the questions asked most often before and after a conversion: data safety, compatibility, networking, maintenance, and security.  
Every answer describes how the current script behaves.

## Data and rollback

### Does it wipe the disk?

- It overwrites the previous system on the system disk; the script is designed as a whole-machine takeover, so only run it on a new machine.
- Previous system files are moved to `/old-root`, but booting has been switched to NixOS, so this is not a dual-boot setup.
- Old data is unrecoverable once you delete `/old-root`.

### Can I keep the previous system?

- You can keep it for a while: the cleanup script asks whether to delete `/old-root`, only `y` / `yes` deletes it, and Enter keeps it.
- You cannot keep a bootable previous system: the conversion rewrites the boot loader, so only one bootable system is left on the disk.
- While it is kept, `/old-root` is just a file tree and cannot boot back into the previous distribution.

### Can I recover after a failure?

- Before a reboot: fix the configuration or switch mirrors and re-run; when Nix is already installed, the installer download is skipped.
- Boot-stage failure (the script exits 1): **do not reboot**; check the log and the cloud provider VNC / serial output first.
- No boot after a reboot: repair it from rescue mode, or use the cloud console's "reinstall system" function.

### How do I roll back to the previous system?

- There is no automatic rollback; `/old-root` is a file backup, not a bootable system.
- If you need the previous distribution, reinstall that system image from the cloud console.
- So before you run it, confirm there is no data you need to keep and that SSH public keys are already in place.

## Compatibility

### Which distributions are supported?

- Tested: OpenCloudOS 8/9, Ubuntu 20.04/22.04/24.04/26.04, Debian 10.2/11.1/12.0/13.2.
- The test environment is Tencent Cloud Lighthouse (KVM + BIOS) and every run ended in NixOS 25.11 with DHCP / SSH / host key working.
- Versions not listed are unverified; upstream experience is that LTS releases are stable and non-LTS releases tend to fail.

### Is ARM supported?

- The script only adds the `vmw_pvscsi` kernel module on x86_64; the rest of the flow does not depend on the architecture.
- There is no ARM record among the verified platforms, ARM is untested, and it is not recommended for production as is.
- You can start with `--dry-run` and check whether the generated `hardware-configuration.nix` looks reasonable.

### Why do OpenVZ / LXC not work?

- These are shared-kernel virtualization setups, and a container cannot install and boot its own kernel.
- The script has to write the MBR / GRUB, replace the kernel, and reboot, and a container has none of those permissions.
- The script has no adaptation for shared kernels, and these platforms are out of scope.

### What about EFI support?

- The script has an EFI branch: probe the ESP, back up the old `/boot` to `/boot.bak`, configure `efiSupport` and `efiInstallAsRemovable`.
- The README states explicitly that "EFI booting is untested".
- On EFI machines, verify with `--dry-run` or on a test instance first.

### Which NixOS versions are supported?

- It probes the latest stable release by default and falls back to `nixos-25.11` if probing fails; the built-in configuration sets `system.stateVersion = "25.11"`.
- Use `--channel=` or the `NIX_CHANNEL` environment variable to pin a version.
- The current tested result is NixOS 25.11.

## Networking and mirrors

### What if there is no external network access?

- The machine must reach a mirror site or your own mirror; a fully offline run does not work.
- Point `NIX_INSTALL_URL`, `NIX_CHANNEL_URL`, `NIX_SUBSTITUTERS` at an internal mirror.
- Add `--no-probe` when you do not want a speed test, and use the fallback order directly.

### The mirror speed test looks wrong

- Everything shows `—`: a middlebox may be blocking large files; try `--fast` or `--prefer=`.
- Suspicious results: delete `/tmp/nixos-infect-cn.probe` and re-run, or wait for the 1-hour TTL to expire.
- `OK` but no speed: the mirror is reachable but its speed cannot be measured; it is still written to substituters and ranked after mirrors with a measured speed.

### Can I use only the official sources?

- Yes: set `NIX_INSTALL_URL=https://nixos.org/nix/install` and `NIX_CHANNEL_URL=https://nixos.org/channels/nixos-25.11`.
- Note that `cache.nixos.org` is filtered out and is not written into the generated configuration.
- Official sources are usually slow from China; the mirror menu in interactive mode also offers `official` directly.

### How do I configure a corporate proxy?

- The script has no proxy flag; `curl` reads the `http_proxy` / `https_proxy` environment variables.
- After the conversion, Nix downloads through its daemon, so the proxy has to be configured in the NixOS configuration separately.
- The simpler route is to switch to a domestic mirror that is reachable.

## Usage and maintenance

### How do I upgrade after the conversion?

```bash
nix-channel --update
nixos-rebuild switch
```

- The channel already points at a domestic mirror, so upgrading needs no extra configuration.
- To change versions: `nix-channel --add <channel URL> nixos && nix-channel --update`.

### Why is the host key kept?

- `finalize_nixos` writes `etc/ssh/ssh_host_*_key*` into `/etc/NIXOS_LUSTRATE`, so NixOS reuses the previous host key.
- The benefit is that client `known_hosts` files report no conflict and logins stay continuous.
- The script also runs `chmod 600` on the host key private keys.

### How much space does the previous system use?

- `/old-root` is the full file tree of the previous system and usually frees several GB, depending on how much the previous system used.
- Check with `du -sh /old-root`; once NixOS works properly, run the cleanup script to delete it.

### Can I run the script again?

- Not recommended. The script is designed as a one-off conversion, and only some steps have idempotent guards:
  - Nix already installed → the installer download is skipped
  - `/etc/NIXOS` already exists → finalize is skipped
  - `/etc/nixos/configuration.nix` already exists → automatic mode reuses it
- To start over, reinstall the system from the cloud console.

### Can I run it on an existing NixOS?

- It is neither needed nor supported: it takes over a system from another distribution.
- To change the configuration of an existing NixOS, edit `/etc/nixos/configuration.nix` and run `nixos-rebuild switch`.

## Security

### What is the risk of a root account without a password?

- After the conversion root has no password, and an SSH public key is the only way to log in.
- Before running, you must `ssh-copy-id root@<server-ip>`, or confirm the cloud provider already injects a public key.
- The configuration summary shows how many public keys there are; when it is 0, add a key before installing.

### What if I lose the public key?

- The public key is the only way in, so SSH is not possible after losing it; first try the cloud provider's "reset password / inject public key" feature.
- You can also boot rescue mode, mount the system disk, and write a new public key into `/root/.ssh/authorized_keys`.
- Once access is back, add a spare public key right away so you do not lose access again.

### What does the log record?

- `/var/log/nixos-infect.log` records timestamped step logs, mirror URLs, and error messages.
- The full output of the installer and of `nix-env` builds is appended in blocks and may contain download URLs and package names.
- SSH private keys are never recorded; the configuration summary only shows how many public keys there are.

### What is the license?

- GPLv3, the same as upstream `elitak/nixos-infect`.
- See `LICENSE` in the repository root for details.

## Related documentation

- [Quick start](./quickstart.md)
- [Troubleshooting guide](./troubleshooting.md)
- [Mirrors and probing](./mirrors.md)
- [Post-install cleanup](./cleanup.md)
- [How it works](./how-it-works.md)
