# Mirrors and probing

[中文](../zh-CN/mirrors.md) | English

This page explains how the script picks the installer, channel and binary cache among five domestic mirrors, and how to use the probing results, the cache and manual overrides.

## Built-in mirrors

| Mirror | Code | Installer | channel | Binary cache | Notes |
| --- | --- | :---: | :---: | :---: | --- |
| TUNA (Tsinghua University) | `TUNA` | Yes | Yes | Yes | All three available, first in the fallback order |
| NJU (Nanjing University) | `NJU` | Yes | Yes | Yes | All three available |
| BFSU (Beijing Foreign Studies University) | `BFSU` | Yes | Yes | Yes | All three available |
| USTC (University of Science and Technology of China) | `USTC` | No | Yes | Yes | Does not provide `/nix/latest/install` |
| SJTUG (Shanghai Jiao Tong University) | `SJTUG` | No | Yes | Yes | Does not provide `/nix/latest/install` |

- The criterion is the third column of the `MIRRORS` array: it is empty for USTC and SJTUG, so the script only tries the three installer variants under `/nix/...`; all of them proved unusable in testing.
- The fallback order is `TUNA → NJU → BFSU → USTC → SJTUG`, used only by `--no-probe` and as a safety net when probing fails.

## The three resource types

### Installer (install)

- Purpose: download the Nix install script, then run it as `sh <installer> --no-channel-add`.
- Preferred URL: `<base>/nix/latest/install`, e.g. `https://mirrors.tuna.tsinghua.edu.cn/nix/latest/install`.
- Candidate variants: `/nix/install`, `/nix/nix-installer/latest/install`.
- Official fallback: `https://nixos.org/nix/install`.

### channel (nix-channels)

- Purpose: serve as the address for `nix-channel --add`, deciding where `nixpkgs` is downloaded from.
- URL shape: `<base>/nix-channels/<channel>`, e.g. `https://mirror.nju.edu.cn/nix-channels/nixos-25.11`.
- Probing method: request the HEAD status code of `<channel>/nixexprs.tar.xz`.

### Binary cache (substituters / store)

- Purpose: reuse prebuilt packages during the build, written into `nix.settings.substituters`.
- URL shape: `<base>/nix-channels/store`, e.g. `https://mirrors.bfsu.edu.cn/nix-channels/store`.
- Probing method: request the HEAD status code of `nix-cache-info`.

## Probing flow

```text
Resolve channel
  → HEAD-check the three resource types for each mirror
  → 1MB range speed test, 3 rounds, median
  → sort by speed
  → generate install / channel / substituters and write the cache
```

1. Resolve the channel: request `https://nixos.org/channels/`, grab `nixos-X.Y` and take the newest; fall back to `nixos-25.11` on failure. `--no-probe` returns `nixos-25.11` directly.
2. Per-mirror checks: the script walks the `MIRRORS` order **serially**, checking installer, channel and binary cache for each mirror in turn; a single request has a 5 second connect timeout and a 30 second total timeout.
3. Failure retries: on status `000` / `500` / `502` / `503` / `504` it retries once after `sleep 1`; `200` / `301` / `302` / `307` / `308` count as available.
4. Speed test: a 1MB range request to `/nix-channels/nixpkgs-unstable/nixexprs.tar.xz`, 3 rounds with the median taken; `--fast` runs 1 round only; a valid download under 256KB counts as a failure.
5. Speed test fallback: when that path is unavailable it falls back to the channel's `nixexprs.tar.xz`, then to the mirror root.
6. Sorting: the fastest mirror wins for the installer and for the channel; for the binary cache every available mirror is ranked by speed in descending order.
7. Generate the final URLs and substituters, then write the probe cache.

- Probing is serial rather than concurrent, so with many mirrors and a poor network the total time is roughly the sum of the individual timeouts.

## Probe cache

| Item | Value |
| --- | --- |
| Path | `/tmp/nixos-infect-cn.probe` (override with `PROBE_CACHE`) |
| TTL | 3600 seconds (1 hour) |
| Contents | A comment header plus four assignment lines: `NIX_INSTALL_URL`, `NIX_CHANNEL`, `NIX_CHANNEL_URL`, `NIX_SUBSTITUTERS` |
| Written when | After probing finishes, after giving up a retry in favour of the fallback order, and after picking mirrors interactively |

- `--skip-probe`: when the cache is fresh and no `--prefer` is given, reuse it directly and restore the environment variables the user had preset.
- When the cache is stale or missing the script asks "run a new speed test now?"; in a non-TTY environment the default is `y`, i.e. probe again as usual.
- The cache is always ignored when `--prefer` is given: it only holds the final URLs of the last round, not the full speed table, so it cannot be re-sorted.
- Reusing the cache reprints neither the probe summary table nor the mirror selection menu.
- The cleanup stage at the end of the install deliberately keeps the cache, so a later `--skip-probe` can reuse it.

## Choosing a mirror manually

### Environment variables (most direct)

| Variable | Effect |
| --- | --- |
| `NIX_INSTALL_URL` | Pin the installer URL, skipping installer probing |
| `NIX_CHANNEL` | Pin the channel name, skipping channel resolution |
| `NIX_CHANNEL_URL` | Pin the channel tarball URL |
| `NIX_SUBSTITUTERS` | Pin the cache list, space-separated; deduplicated and `cache.nixos.org` removed automatically |

- When `NIX_INSTALL_URL`, `NIX_CHANNEL` and `NIX_CHANNEL_URL` are all set explicitly, the script skips probing entirely.

### --prefer=NAME

- Only `TUNA` `NJU` `BFSU` `USTC` `SJTUG` are accepted; a misspelling exits immediately.
- It only affects the first choice for the installer and the channel, and requires that mirror to serve the resource, otherwise it falls back to the fastest mirror.
- It does not change the order of the binary cache; the cache list stays in descending speed order.

### --no-probe

- The installer is pinned to TUNA, the channel to TUNA's `nixos-25.11`.
- substituters are written in full in the order TUNA, NJU, BFSU, USTC, SJTUG, and Nix tries them in turn.
- No speed test request is issued, and it no longer asks whether to probe again.

## Official fallback

- When no mirror provides an installer, it falls back to `https://nixos.org/nix/install`.
- The channel likewise falls back to `https://nixos.org/channels/<channel>`.
- The interactive installer and channel menus always contain an `official` option, so you can pick the official source deliberately.
- The generated config never contains `cache.nixos.org`: the script strips it in `normalize_substituters`; as the README explains, the official cache is left to Nix itself as a last resort.

## Reading the speed results

- The summary table columns are `Mirror`, `Install`, `Channels`, `Store`, and each cell shows the measured speed of that mirror.
- Units: `MB/s` from 1 MiB/s up, `KB/s` from 1 KiB/s up, `B/s` below that; a speed of 0 shows `—`.
- Colours: green for ≥1 MB/s, yellow for ≥300 KB/s, red below that, dim for no data.
- `NOT_FOUND` (red): that resource type is unavailable and will not be selected.
- `OK` (yellow, usually in the Store column): the mirror is reachable but cannot be speed-tested (the large file is refused or missing), so it is still written into substituters but ranked after the tested mirrors.
- A footnote below the table explains the speed test method and what `--fast` does.
- To compare several mirrors quickly, add `--fast` for a single round; to force a re-probe, delete the cache file first or trigger a new probe with `--prefer`.

## Adding a mirror

- Edit the `MIRRORS` array in `nixos-infect.sh`; the format is `NAME|base_url|known_install_path`.
- Leave the third column empty for a mirror without `/nix/latest/install`; the script then tries the three variants in `INSTALL_VARIANTS` automatically.
- Before adding one you must test all three resource types: the installer is downloadable, `/nix-channels/<channel>/nixexprs.tar.xz` works, and `/nix-channels/store/nix-cache-info` works.
- Update the fallback order in `probe_fallback`, the `--prefer` help text and this document at the same time.
- Validation of `--prefer` walks `MIRRORS` directly, so a new code needs no extra registration.

## Related documentation

- [CLI reference](./cli.md)
- [Troubleshooting guide](./troubleshooting.md)
- [Development](./development.md)
