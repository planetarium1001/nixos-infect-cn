# CLI reference

[中文](../zh-CN/cli.md) | English

This page lists every flag, environment variable, output rule and abort condition of `nixos-infect.sh`, as a lookup table for deployments.

## Basic usage

### Piped execution (most common)

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh \
  | bash -s -- --lang=zh
```

- `-s --` passes the following arguments to the script instead of letting bash consume them.
- A pipe has no terminal, so the script does not ask anything and every option takes its default.

### Download and run

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh -o nixos-infect.sh
bash nixos-infect.sh --lang=zh
```

- Use this form when you need `--interactive` to edit the configuration.
- You can also run `bash nixos-infect.sh --help` first to confirm the flags of the current version.

### Set the output language

```bash
bash nixos-infect.sh --lang=zh   # Chinese
bash nixos-infect.sh --lang=en   # English (default)
```

- `--lang=zh_CN` and `--lang=zh_TW` are equivalent to `zh`.
- The help text printed by `--help` is always English.

## Flags

### General

| Flag | Values | Default | Description |
| --- | --- | --- | --- |
| `--lang=CODE` | `en` `zh` | `en` | Output language; `zh_CN` / `zh_TW` are accepted too |
| `--interactive` | — | off | Interactive mode: pick mirrors, open a shell to edit the config; needs a TTY |
| `--auto` | — | on | Fully automatic, never enters the editing flow |
| `--yes` | — | off | Skip redundant confirmations (prompts only appear in the interactive flow) |
| `--verbose` | — | off | Print `[DEBUG]`, and pass through the full installer and Nix output verbatim |
| `--no-color` | — | off | Disable ANSI colours (same as `NO_COLOR=1`) |
| `--help` / `-h` | — | — | Print help and version, then exit 0 |

### Probing

| Flag | Values | Default | Description |
| --- | --- | --- | --- |
| `--skip-probe` | — | off | Reuse a probe cache younger than 1 hour; ask whether to probe again when it is stale or missing |
| `--no-probe` | — | off | No probing at all; use the fallback order, channel pinned to `nixos-25.11` |
| `--fast` | — | off | Probe each mirror for 1 round only (default: 3 rounds, median) |
| `--prefer=NAME` | `TUNA` `NJU` `BFSU` `USTC` `SJTUG` | empty | Preferred mirror; the name is upper-cased for validation, an invalid value exits 1 |
| `--channel=CHANNEL` | e.g. `nixos-25.11` | auto-probed | Pin the channel; falls back to `nixos-25.11` if probing fails |

### Configuration

| Flag | Values | Default | Description |
| --- | --- | --- | --- |
| `--template=TYPE:PATH` | `configuration` `hardware` `networking` | built-in template | External template overrides the built-in one, repeatable; abort if the file is unreadable |
| `--networking` | — | auto-detected | Force generation of `networking.nix` (static IP); abort when no interface / IP can be read |
| `--no-networking` | — | auto-detected | Never generate `networking.nix` (DHCP case) |

### Installation

| Flag | Values | Default | Description |
| --- | --- | --- | --- |
| `--dry-run` | — | off | Probe and generate the config into `/tmp/nixos-infect-dryrun` only, no install |
| `--no-infect` | — | off | Do only the preparation (write `/etc/nix/nix.conf`, temporary swap), skip the install |
| `--no-reboot` | — | off | Do not reboot after install, so you can inspect the artifacts first |
| `--no-swap` | — | off | Do not create the 1GB temporary swap; also skipped automatically when the previous system has a swap device |

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `NIX_INSTALL_URL` | auto-probed | Nix installer URL |
| `NIX_CHANNEL` | auto-probed | NixOS channel, e.g. `nixos-25.11` |
| `NIX_CHANNEL_URL` | auto-probed | channel tarball URL |
| `NIX_SUBSTITUTERS` | auto-probed | Space-separated; deduplicated and `https://cache.nixos.org` filtered out automatically |
| `CONFIG_DIR` | `/etc/nixos` | Configuration output directory |
| `LOG_FILE` | `/var/log/nixos-infect.log` | Log path; file logging is turned off automatically when it is not writable |
| `NO_REBOOT` | empty | Takes effect when non-empty, same meaning as `--no-reboot` |
| `NO_SWAP` | empty | Takes effect when non-empty, same meaning as `--no-swap` |
| `NO_INFECT` | empty | Takes effect when non-empty, same meaning as `--no-infect` |

- Environment variables that are set explicitly win over probing results: neither probing nor the cache overwrites an existing value.
- When `NIX_INSTALL_URL`, `NIX_CHANNEL_URL` and `NIX_CHANNEL` are all set, the script skips probing entirely.
- If `NIX_SUBSTITUTERS` is empty after filtering, the generated config contains no `substituters` block.

## Common combinations

**Fast install in China**: the default flow, which probes automatically and picks the fastest mirror.

```bash
bash nixos-infect.sh --lang=zh --auto
```

**Edit the config interactively**: pick the mirrors first, then edit `/etc/nixos/configuration.nix` in a shell.

```bash
bash nixos-infect.sh --lang=zh --interactive
```

**Rehearse only**: generate the config without touching the system; the artifacts land in `/tmp/nixos-infect-dryrun`.

```bash
bash nixos-infect.sh --lang=zh --dry-run
```

**Pin a mirror**: effective only when that mirror serves the resource, otherwise it falls back to the fastest one.

```bash
bash nixos-infect.sh --lang=zh --prefer=TUNA
```

**Pin the channel**: useful for reproducing an issue or aligning versions.

```bash
bash nixos-infect.sh --lang=zh --channel=nixos-25.11
```

**No network probing**: no speed test, fastest start-up, uses the fallback order and `nixos-25.11`.

```bash
bash nixos-infect.sh --lang=zh --no-probe
```

## Output and logs

### Terminal output

- `[INFO]` and `==>` go to stdout; `[WARN]` and `[ERROR]` go to stderr.
- Interactive menus are written to stderr, so stdout only carries the selected key and is not swallowed by `$(...)`.
- Without a TTY (piped execution) stdin is never read; prompts take their defaults and are marked "non-interactive".
- Colours are enabled only when stdout is a terminal and `NO_COLOR` is unset.
- Long steps wrapped by `run_quiet` show only a spinner, the elapsed seconds and the last output line.

### Log file

- Path `/var/log/nixos-infect.log`, one line per entry in the form `date time [LEVEL] content`.
- The full output of the installer and of the `nix-env` build is appended in blocks headed `===== time label =====`.
- When `LOG_FILE` is not writable or is empty, file logging is turned off and terminal output is unaffected.
- On a failed step the terminal echoes only the last 30 lines; the log holds the complete output.

## Exit and abort conditions

| Trigger | Script behaviour | How to recover |
| --- | --- | --- |
| Not root | Prints `Must run as root` and exits 1 | Re-run as root |
| `curl` and `wget` both missing | Tries wget as a fallback or installs via apt first, exits 1 if that still fails | Install curl manually, then re-run |
| `bzcat` / `xzcat` / `tar` / `ip` / `awk` etc. missing | Exits 1 | Install the missing dependencies with apt/dnf, then re-run |
| Invalid flag (unknown flag, misspelled `--prefer`, wrong `--template` type) | Exits 1 | Fix the flags according to `--help` |
| `--networking` forced but no interface or IPv4 address can be read | Refuses to write an empty config and exits 1 | Use `--no-networking` or write `networking.nix` by hand |
| `configuration.nix` syntax error and no TTY | Exits 1, printing the first 20 lines of the error to stderr | Fix the file and re-run; with a TTY you can enter the shell and retry |
| System build (`nix-env --set`) fails and no TTY | Exits 1 | Fix the config according to the log, then re-run |
| Installer download fails, or `nix-channel` fails | Exits 1 | Change the mirror or set `NIX_INSTALL_URL`, then re-run |
| Boot loader installation fails | Exits 1, warning that the machine may not boot NixOS | Do not reboot; check the VNC and the log first |
| Backing up `/boot` to `/boot.bak` fails under EFI | Exits 1, to avoid breaking `/boot` | Check the mount points manually, then re-run |

- The root check runs after the config is generated and before installation, so `/etc/nixos` may already have been written when it fails.
- The current version has no "abort when `NIXOS_LUSTRATE` is empty" check: the manifest is only appended in `finalize_nixos`.
- For a first run, install with `--no-reboot`, confirm that `cat /etc/NIXOS_LUSTRATE` is non-empty, then reboot manually.

## Related documentation

- [Installation](./installation.md)
- [Mirrors and probing](./mirrors.md)
- [Configuration](./configuration.md)
- [Troubleshooting guide](./troubleshooting.md)
