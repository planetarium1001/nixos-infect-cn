# How it works

[中文](../zh-CN/how-it-works.md) | English

This page breaks `nixos-infect.sh` down into its seven stages in execution order, with the input, output, and failure behavior of each one.  
After reading it you will know which files the script touches and why a reboot lands in NixOS.

## Overview

```text
[1] Probing       HEAD checks + 1MB speed test, picks install / channel / store
     ↓
[2] Configuration renders /etc/nixos/*.nix, editable in interactive mode
     ↓
[3] Preflight     checks root, dependencies, swap; writes /etc/nix/nix.conf
     ↓
[4] Install Nix   downloads the installer from a domestic mirror, installs to /nix
     ↓
[5] Build system  configures the channel, builds the system profile
     ↓
[6] Boot takeover writes LUSTRATE, installs GRUB, invalidates the host cache
     ↓
[7] Reboot        reboots; the first boot moves the previous system to /old-root
```

## Stage details

### 1. Probing

- Input: `curl`, the network, and `--prefer`, `--fast`, `--skip-probe`, `--no-probe`.
- Action: probe the installer, channel, and binary cache for every mirror; measure speed with 1MB range requests, 3 rounds, take the median.
- Output: `NIX_INSTALL_URL`, `NIX_CHANNEL`, `NIX_CHANNEL_URL`, `NIX_SUBSTITUTERS`, cached in `/tmp/nixos-infect-cn.probe` with a 1-hour TTL.
- Failure: a failed speed test does not block anything, mirrors are ranked by reachability; `--no-probe` or a declined re-test uses the TUNA → NJU → BFSU → USTC → SJTUG fallback.
- Last resort: when no mirror serves any of the three resource types, install and channel fall back to the official `nixos.org` URLs.

### 2. Configuration

- Input: probe results, hostname/domain, `/root/.ssh/authorized_keys`, static network detection results.
- Action: render with the built-in `SECTION 11` templates, inheriting the previous system hostname by default; `--template` can replace a single template.
- Output: `/etc/nixos/configuration.nix`, `hardware-configuration.nix`, plus `networking.nix` when a static IP is used.
- Failure: exits immediately when a template is unreadable, or when `--networking` is forced but no interface/IP can be detected; no half-written files.
- Interactive: `--interactive` opens a shell for edits and the summary re-reads the files; no editing without a TTY.
- Reuse: in automatic mode an existing `configuration.nix` is kept, so user edits are not overwritten.

### 3. Preflight

- Input: the current system environment, `/etc/nix/nix.conf`.
- Action: confirm root and dependencies such as `curl`/`bzcat`/`xzcat`/`ip`/`tar`, fix host key permissions, create a 1GB temporary swap when needed.
- Output: `/etc/nix/nix.conf` gains the domestic substituters and the official signing public keys, other user lines are kept.
- Failure: exits on a missing dependency or a non-root user; the boot loader is untouched at this point, so the machine still boots the previous system.
- dry-run: ends before preflight, leaving only the configuration and changing nothing on the system.

### 4. Install Nix

- Input: the installer script behind `NIX_INSTALL_URL`.
- Action: skipped when Nix is already installed; otherwise creates the `nixbld` group and build users, downloads the installer, and runs it with `--no-channel-add`.
- Output: `/nix` and `~/.nix-profile`, the environment the later builds need.
- Failure: exits when the download fails or the installer returns non-zero; for mirror problems, re-run with a different `--prefer`.
- Compatibility: without `curl` it tries to fake a `curl` function with `wget`, and only reports an error when that also fails.

### 5. Build system

- Input: `NIX_CHANNEL_URL`, `/etc/nixos/*.nix`.
- Action: `nix-channel --add/--update`, then `nix-instantiate --parse` as a syntax check, then build the system profile.
- Output: `/nix/var/nix/profiles/system`, the full system closure of the new NixOS.
- Failure: syntax or build errors drop into a shell for retries; without a TTY it exits and tells you to fix the configuration.
- Progress: `run_quiet` shows one progress line on the terminal and writes the full output to the log.

### 6. Boot takeover

- Input: the built system profile, partition information (`grubdev` or ESP).
- Action: writes `/etc/NIXOS` and the cleanup script, appends the critical paths to `/etc/NIXOS_LUSTRATE`, runs `switch-to-configuration boot`.
- EFI: backs up the old `/boot` to `/boot.bak` first, then mounts the ESP and wipes its old contents.
- Cache invalidation: `touch /boot/vmlinuz-*` and `/boot/initrd.img-*` so a host machine that resolves the boot entry itself re-reads them.
- Flush to disk: reboot is only allowed after `sync`; a failed GRUB install or `/boot` backup aborts.

### 7. Reboot and cleanup

- Input: `NO_REBOOT`, the current root filesystem.
- Action: removes the temporary swap, cleans up dry-run leftovers, keeps the probe cache; runs `reboot` by default.
- First boot: NixOS consumes `/etc/NIXOS_LUSTRATE`, moves the previous system into `/old-root`, and keeps the paths listed in the manifest.
- Output: a NixOS you can log into; the previous system is in `/old-root` and the cleanup script is in `/root`.
- Failure: the cleanup script refuses to run outside NixOS; a stuck shutdown is covered in the troubleshooting guide.
- Manual finishing step: once everything looks right, run `bash /root/nixos-infect-cleanup.sh`.

## Key mechanisms

### NIXOS_LUSTRATE takeover

- Why it is needed: an overwrite install cannot simply format the root partition; the new system has to move the old root aside first.
- `finalize_nixos` appends `etc/nixos`, `etc/resolv.conf`, the channel link, the cleanup script, and the SSH host key to the manifest.
- On first boot NixOS reads the manifest, the old root contents move into `/old-root`, and the listed paths stay in the new system.
- This version has no separate "abort when the manifest is empty" check; after installing with `--no-reboot`, confirm the manifest is non-empty before you reboot.

### /etc/NIXOS idempotent marker

- Why it is needed: the script may be re-run after a network or build failure, and the takeover must not run twice.
- `finalize_nixos` checks `/etc/NIXOS` at the start; when it exists the whole block is skipped and the result is treated as done.
- The marker only guards the install phase; on a re-run the generated `/etc/nixos` configuration is detected and reused as well.

### Host boot cache invalidation

- Why it is needed: some cloud host machines resolve and cache `/boot/grub/grub.cfg` themselves, so a changed GRUB on disk still has no effect.
- Symptom: no GRUB menu in VNC; the machine boots the previous system again even though the on-disk boot configuration looks completely correct.
- Remedy: after installing the boot loader, `touch` `/boot/vmlinuz-*` and `/boot/initrd.img-*` to trigger a re-read through the timestamp change.
- Harmless: platforms that boot from the on-disk GRUB are unaffected, and the file contents do not have to change.

### host key retention

- Why it is needed: avoids an `ssh` host key changed warning and keeps the client `known_hosts` usable.
- Implementation: `/etc/NIXOS_LUSTRATE` lists `etc/ssh/ssh_host_*_key*`, so the old host key is not moved into `/old-root`.
- Before installing, the script also runs `chmod 600` on these private keys to avoid permission warnings on the NixOS side.
- The NixOS SSH service finds the key already present and does not regenerate it, so the fingerprint stays the same.

### substituters injection

- Why it is needed: `cache.nixos.org` is the default, and downloads and builds from China are very slow or fail outright.
- `normalize_substituters` deduplicates the list and filters out `cache.nixos.org`.
- Two places are written at once: `/etc/nix/nix.conf` for install time, and `nix.settings.substituters` in `configuration.nix` for after the reboot.
- Nix may still append the official cache at the end as a fallback, but the generated configuration does not write it deliberately.

## Generated files

| Path | Purpose | Created when | Kept after reboot |
| --- | --- | --- | --- |
| `/etc/nixos/*.nix` | Target system configuration | Configuration stage | Kept (listed in the LUSTRATE manifest) |
| `/etc/nix/nix.conf` | Install-time substituters and signing public keys | Preflight stage | Regenerated by NixOS from `configuration.nix` |
| `/etc/NIXOS_LUSTRATE` | Takeover manifest | Takeover stage | Gone after the first boot consumes it |
| `/root/nixos-infect-cleanup.sh` | Post-reboot cleanup script | Takeover stage | Kept until cleanup finishes |
| `/old-root` | Root filesystem of the previous system | First boot into NixOS | Kept until you clean up manually |
| `/boot.bak` | Backup of the old `/boot` on EFI | Takeover stage (EFI only) | Kept until the cleanup script deletes it |
| `/var/log/nixos-infect.log` | Install log | While running | Usually moved to `/old-root/var/log/` with the previous system |
| `/tmp/nixos-infect-cn.probe` | Mirror probe cache | Probing stage | Not kept (`boot.tmp.cleanOnBoot`) |

## Script structure

Line numbers come from `grep -n "SECTION" nixos-infect.sh` and are approximate; they shift after edits.

| SECTION | Responsibility | Approx. lines |
| --- | --- | --- |
| 1 | Constants, defaults, paths, runtime state | 41–92 |
| 1.1 | Color definitions | 93–108 |
| 2 | Logging functions and `MSG_EN` / `MSG_ZH` | 110–341 |
| 3 | UI primitives: menus, confirmations, shell, progress | 343–532 |
| 4 | Shared utilities: progress compression, `run_quiet`, substituters, channel | 534–691 |
| 5 | System probing: EFI, root device, swap, static networking | 693–818 |
| 6 | Mirror probing, speed test, cache, interactive selection | 820–1376 |
| 7 | Template rendering, configuration generation, summary and edit flow | 1378–1693 |
| 8 | Dependency checks, Nix install, build, boot takeover | 1695–2033 |
| 9 | Pre-reboot cleanup and cleanup script generation | 2035–2132 |
| 10 | `main`, argument parsing, help text | 2134–2341 |
| 11 | Built-in templates: configuration / hardware / networking | 2343–2468 |

## Design trade-offs

- Idempotency first: a re-run does not repeat the takeover, existing configuration is kept by default, and a failed run can be retried in place.
- Change as little upstream logic as possible: edits concentrate on mirror probing, Chinese wording, and boot takeover.
- Single file, no build step: templates are built in, `curl | bash` just works, and no packaging step is introduced.
- No stdin reads without a TTY: when run through a pipe, `read` would swallow the script itself, so menus and confirmations always take the default.
- Tolerating errors beats aborting, except at safety points: failed probes can fall back; a failed `/boot` backup or a failed GRUB install must abort.
- No extra self-checks: `NIXOS_LUSTRATE` is not validated before the takeover; when you need that, use `--no-reboot` and check it yourself.
- Explicit configuration wins: environment variables and flags outrank probe results, so values you set are never overwritten by probing.
- China-accessible network first: filters `cache.nixos.org`, probes speed automatically, and caches results to reduce repeated probing.

## Related documentation

- [Installation guide](./installation.md)
- [Configuration](./configuration.md)
- [Post-install cleanup](./cleanup.md)
- [Project conventions and contributing](./development.md)
