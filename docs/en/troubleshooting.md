# Troubleshooting guide

[中文](../zh-CN/troubleshooting.md) | English

Covers common nixos-infect-cn failures: a failed install, a reboot that does not reach NixOS, and lost SSH access.  
Start with the symptom table, then jump to the matching section.

## Collect information first

- Logs: `/var/log/nixos-infect.log`; adding `--verbose` also writes debug output and the full run into it.
- Screen: VNC / serial output from the cloud console, especially the boot menu and the kernel log.
- Commands: the full command, its flags, when it ran, and which stage failed.

```bash
bash nixos-infect.sh --lang=zh --verbose
tail -n 100 /var/log/nixos-infect.log
```

| Category | Contents |
| --- | --- |
| Environment | Cloud provider and instance type, previous OS version, BIOS/EFI, `uname -m`, virtualization type |
| Run | Full command, tail of the log, failing stage, whether `--no-reboot` was used |
| Evidence | VNC/serial screenshots, `/etc/NIXOS_LUSTRATE`, `/proc/cmdline`, SSH error message |

Once the machine has rebooted into NixOS, the old log is usually at `/old-root/var/log/nixos-infect.log`.

## Symptom table

| Symptom | Most likely cause | Go to |
| --- | --- | --- |
| Still the previous system after reboot | Host machine cached the `/boot` resolution result | [Still boots the old system](#still-boots-the-old-system) |
| SSH times out or is refused after reboot | Stuck shutting down, missing public key, host key change | [SSH unreachable after reboot](#ssh-unreachable-after-reboot) |
| Script exits midway, no reboot | Bad configuration, missing dependency, unreachable mirror | [Installer exits midway](#installer-exits-midway) |
| `configuration.nix failed to parse` | Syntax error from a manual edit | [configuration.nix syntax error](#configurationnix-syntax-error) |
| Installer download or build fails | Unreachable mirror, not enough disk or memory | [Download or build failures](#download-or-build-failures) |
| Downloading the script gives 451 or an old version | Gitee review / jsDelivr cache | [Gitee returns 451 or jsDelivr serves a stale copy](#gitee-returns-451-or-jsdelivr-serves-a-stale-copy) |
| Cleanup script refuses to run | NixOS has not booted yet | [Cleanup script refuses to run](#cleanup-script-refuses-to-run) |
| No boot at all after install | OpenVZ / LXC shared kernel | [Unsupported virtual machines and VPS](#unsupported-virtual-machines-and-vps) |

## Still boots the old system

**Symptom**: the install completed and the machine rebooted, but `uname -a` still reports the previous distribution and VNC may show no GRUB menu; **Cause**: the host machine resolves and caches `/boot/grub/grub.cfg` itself, so it keeps booting the old entry even after GRUB is rewritten.  
**What to do**:

```bash
cat /etc/NIXOS_LUSTRATE
tr ' ' '\n' < /proc/cmdline | grep BOOT_IMAGE
touch /boot/vmlinuz-* /boot/initrd.img-* && reboot
```

- Manifest still present = NixOS never booted; `BOOT_IMAGE` pointing at the old kernel = the host used the old boot entry.
- `touch` the kernel files and reboot to force the host to re-read `/boot`; when GRUB does show up, you can also select NixOS by hand.

**How to confirm**: `BOOT_IMAGE` becomes `/nix/store/.../kernel`, and `/etc/NIXOS_LUSTRATE` is gone.

## SSH unreachable after reboot

**Symptom**: `ssh root@<server-ip>` times out, returns `Connection refused`, or warns that the host key changed; **Cause**: stuck shutting down, missing public key, host key conflict, or a wrong static network configuration.  
**What to do**:

- Look at VNC first; if the screen is stuck on shutdown, reboot once by hand.
- If `SSH authorized keys` in the configuration summary is `0`, go back to the previous system, add a public key, and install again.
- On a host key conflict, remove the old entry and reconnect:

```bash
ssh-keygen -R <server-ip>
ssh -o StrictHostKeyChecking=accept-new root@<server-ip>
```

- With a static IP, check the address and gateway in `/etc/nixos/networking.nix`.

**How to confirm**: login works, `nixos-version` reports `25.11`, and `systemctl status sshd` is healthy.

## Installer exits midway

**Symptom**: the script exits with a non-zero status, the machine did not reboot, and the previous system is still running.
**Cause**: configuration syntax error, missing critical dependency, unreachable mirror, build failure, or `--no-infect` was passed on purpose.
**What to do**:

```bash
tail -n 50 /var/log/nixos-infect.log
cat /etc/NIXOS_LUSTRATE 2>/dev/null || echo "not staged yet"
ls -l /nix/var/nix/profiles/system 2>/dev/null
```

- The last `[ERROR]` line in the log names the failing stage; continue with "Download or build failures" or "configuration.nix syntax error" below.
- Re-running the script is safe: an installed Nix, a generated configuration, and a completed takeover are all skipped.
- This version has no separate "abort when `NIXOS_LUSTRATE` is empty" check; after installing with `--no-reboot`, confirm the manifest is non-empty before you reboot.

**How to confirm**: the log contains `Installation complete`, and `/etc/NIXOS_LUSTRATE` is complete.

## configuration.nix syntax error

**Symptom**: `configuration.nix failed to parse`, or a Nix syntax error during the build stage; **Cause**: a manual edit dropped a semicolon or a bracket, or external template substitution left something that is not a valid Nix expression.  
**What to do**:

```bash
nix-instantiate --parse /etc/nixos/configuration.nix
```

- With a TTY the script opens a shell; after fixing the file, `exit` retries automatically. Without a TTY it aborts.
- Without a TTY, use the downloaded script with `--interactive`, or with `--template=configuration:/root/fixed.nix`.
- If that still fails, download the script and edit the built-in `SECTION 11` template; `--no-reboot` lets you fix the configuration before rebooting.

**How to confirm**: `--parse` prints nothing, the re-run build succeeds, and `/nix/var/nix/profiles/system` is created.

## Download or build failures

**Symptom**: `Failed to download the Nix installer`, a channel download failure, or a failure to build the system closure; **Cause**: mirror unreachable or too slow, out of disk, out of memory, transient network trouble.  
**What to do**:

- Switch mirrors: `--prefer=TUNA`, or `--no-probe` to use the fallback order, `--fast` for a shorter speed test.
- Add `--verbose` and check the log and the last 30 lines of the failing command.
- When memory is short, add swap first (1GB is created by default, `--no-swap` disables it); check disk with `df -h / /nix /tmp`.

```bash
bash nixos-infect.sh --lang=zh --prefer=TUNA --verbose
free -h
```

**How to confirm**: the log contains `Installation complete` and no `[ERROR]`; the system profile points at a valid closure.

## Gitee returns 451 or jsDelivr serves a stale copy

**Symptom**: `curl` gets a 451 or an empty file when downloading the script, or the version you run is not the latest; **Cause**: Gitee reviews larger files so `raw` may return `451`, and jsDelivr caches branch references.  
**What to do**:

- Gitee 451: switch to jsDelivr or a GitHub acceleration URL, and do not make Gitee your only source.
- Stale jsDelivr: replace `@master` with a concrete commit id, or purge the cache.

```bash
curl -fsSL https://purge.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh
```

**How to confirm**: `bash nixos-infect.sh --help | head -1` prints `nixos-infect-cn 2026-10-01`.

## Cleanup script refuses to run

**Symptom**: running `/root/nixos-infect-cleanup.sh` reports `this does not look like a booted NixOS system`; **Cause**: the script requires `/run/current-system` to exist and `/etc/os-release` to contain `ID=nixos`.  
**What to do**:

```bash
grep '^ID=' /etc/os-release
ls -d /run/current-system
```

- If either check fails, NixOS has not booted yet; reboot and run it again.
- If you are already in NixOS and it still fails, check whether `/etc/os-release` was edited by hand.

**How to confirm**: `ID=nixos` and `/run/current-system` exist, and a re-run asks about `/old-root`.

## Unsupported virtual machines and VPS

**Symptom**: no boot after install, or the installer cannot write the boot loader / kernel; **Cause**: shared-kernel virtualization such as OpenVZ and LXC has no kernel or boot loader of its own, so NixOS cannot take over.  
**What to do**:

```bash
systemd-detect-virt
cat /proc/1/cgroup
ls -d /proc/vz 2>/dev/null
```

- Output of `openvz` or `lxc`, or an existing `/proc/vz`, means a shared kernel; use a KVM / Xen HVM instance instead.
- The script does not block these environments, so check before you run it.

**How to confirm**: `systemd-detect-virt` on the new instance prints `kvm` or `none`; EFI is untested, so prefer BIOS.

## Still stuck

- Script version: `bash nixos-infect.sh --help | head -1`.
- Environment: cloud provider, instance type, previous OS version, `uname -a`, `systemd-detect-virt`, BIOS/EFI.
- The full command and its flags, and which stage failed.
- The tail of `/var/log/nixos-infect.log` (or `/old-root/var/log/nixos-infect.log`).
- VNC / serial screenshots, including the GRUB menu and kernel errors.
- After the reboot, `/etc/NIXOS_LUSTRATE` and `tr ' ' '\n' < /proc/cmdline | grep BOOT_IMAGE`.
- The complete SSH error, and whether public key login is configured.

## Related documentation

- [Installation guide](./installation.md)
- [Post-install cleanup](./cleanup.md)
- [How it works](./how-it-works.md)
- [Flags and environment variables](./cli.md)
