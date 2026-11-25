# Project conventions and contributing guide

[中文](../zh-CN/development.md) | English

This page covers the layout of nixos-infect-cn, the code / comment / i18n / logging conventions, and the check, test, and submission flow.  
The goal is to keep a single-file script readable and verifiable, and to keep the README and the bilingual docs in sync.

## Directory structure

```text
nixos-infect-cn/
├── nixos-infect.sh        # single-file install script with built-in templates
├── nixos-infect.en.sh     # English-comment edition, same code as the main script
├── README.md              # Chinese readme, one source of project facts
├── README.en.md           # English readme, kept in sync with the Chinese one
├── README.upstream.md     # original upstream readme
├── LICENSE                # GPLv3
├── .editorconfig          # editor formatting conventions
├── screenshots/           # screenshots shared by the README and docs
│   ├── screenshot.png
│   ├── quickstart.png
│   ├── interactive_0.png
│   ├── interactive_1.png
│   ├── interactive_2.png
│   └── cleanup.png
├── scripts/
│   └── verify-comment-parity.sh  # checks that both scripts share the same code
└── docs/
    ├── README.md          # documentation index
    ├── zh-CN/             # Chinese documentation
    └── en/                # English documentation, file names match zh-CN one to one
```

| Item | Purpose |
| --- | --- |
| `nixos-infect.sh` | The only executable artifact; behavior changes go here and nowhere else |
| `nixos-infect.en.sh` | English-comment copy; its code must match the main script |
| `README.md` / `README.en.md` | Warnings, platform matrix, quick start, full flag table |
| `README.upstream.md` | Keeps the upstream readme for comparing behavior differences |
| `screenshots/` | Docs reference them as `../../screenshots/xxx.png` |
| `docs/zh-CN/` | Long-form Chinese docs; commands, flags, and paths stay in English |
| `docs/en/` | English docs; heading levels match the Chinese tree |
| `scripts/` | Maintenance checks, not involved in installation |

## Code conventions

- Use Bash throughout (associative arrays need Bash 4+), with the fixed shebang `#!/usr/bin/env bash`; never run it with `sh`.
- The main script only enables `set -o pipefail`, never `set -e`: probing, `grep`, `read`, and many other commands are allowed to fail, so each must be checked explicitly and have a fallback.
- The cleanup script is the opposite and uses `set -euo pipefail`: users run it by hand, so it must stop at the first failure.
- `pipefail` is not POSIX, which is why every documented invocation is `bash` or `| bash`.
- Always quote variable references: `"$var"`, `"${arr[@]}"`; use `"${var:-}"` for the ones that may be unset.
- Declare variables inside functions with `local`; name functions in `snake_case` starting with a verb, such as `probe_run` or `write_nix_conf`.
- Indexed arrays hold ordered lists (`MIRRORS`, `INSTALL_VARIANTS`), associative arrays hold lookup tables (`MSG_EN`, `R_STORE_URL`).
- Prefer `[ ]` for tests and `case` for multiple branches; do not pretend to be POSIX when a Bash feature is actually needed.
- Editors follow `.editorconfig`: UTF-8, LF, 2-space indentation; Markdown does not trim trailing spaces (they are used for line breaks).

## Comment conventions

- File header: version, purpose, usage, upstream origin; update the date whenever the version number changes.
- Section titles: `# SECTION N: responsibility` plus a separator line; put new functions in the section whose responsibility matches, instead of piling code across sections.
- Function headers: state purpose, usage, output, and side effects; anything that writes files, changes globals, or calls `exit` must say so.
- Inline comments: explain "why" only, never restate the code; platform differences, non-TTY behavior, and safety fallbacks always need a comment.
- English-comment edition: `nixos-infect.en.sh` exists for English readers; translate comments only and never change code or strings. Land code changes in `nixos-infect.sh` first, then mirror them into the English edition.

Good example:

```bash
# Usage: run_quiet "description" cmd [args...]
# Output: one progress line on the terminal; full output appended to LOG_FILE
# Returns: exit status of the command that ran
run_quiet() {
  ...
}
```

Bad example:

```bash
# Set a variable
local x=1
# Loop 10 times
for i in $(seq 1 10); do
```

- Comments are written in Chinese; user-facing text must not be hard-coded in functions and goes through i18n.
- Platform-specific "why" knowledge stays next to the code, for example the host machine cache, or why stdin cannot be read when run through a pipe.
- Do not commit large blocks of commented-out old implementations; keep history in git.

## Wording and i18n conventions

- New strings must be added to both `MSG_EN` and `MSG_ZH` with the same key; `msg` falls back to English when the Chinese text is missing.
- Keys use `lower_snake_case` with a scenario prefix: `probe_`, `config_`, `install_`, `cleanup_`.
- Use `%s` placeholders for variables and call `msg_fmt key args...`; never assemble whole sentences by hand.
- Templates may start with `-`, so `msg_fmt` uses `printf --` and keeps the `SC2059` suppression comment.
- Without a TTY, `ui_can_prompt` returns false: menus do not read stdin, `confirm` takes the default, and `enter_shell` returns 1.
- Menus, prompts, and warnings go to stderr; stdout carries results only, so `$(...)` does not pick up noise.

## Logging and output conventions

| Function | Purpose | Output destination |
| --- | --- | --- |
| `log_info` | Normal progress and success messages | stdout + log |
| `log_step` | Stage headings | stdout + log |
| `log_warn` | Recoverable problems | stderr + log |
| `log_error` | Failures and abort reasons | stderr + log |
| `log_debug` | Troubleshooting detail, `--verbose` only | stdout + log |

- One log line expresses one thing; do not dump multi-line command output straight into `log_info`.
- Slow commands always go through `run_quiet`: one progress line on the terminal, full output in the log, and the last 30 lines printed on failure.
- When `LOG_FILE` is not writable, `_log_write` disables file logging automatically; installation must not be interrupted because of it.

## Static checks

```bash
bash -n nixos-infect.sh
shellcheck -x nixos-infect.sh
```

- `SC2034`: template variables are referenced indirectly through `${!var}`, so keep `# shellcheck disable=SC2034` and state the reason.
- `SC1090`: `source` loads files generated at runtime (probe cache, nix profile), so suppress it inline.
- `SC2059`: the format string given to `msg_fmt` comes from i18n and is intentional, so add a suppression comment.
- Do not silence new warnings globally; first decide whether the warning is real, then fix the code or suppress it locally.

To verify that the English edition differs from the main script only in comments:

```bash
bash scripts/verify-comment-parity.sh
```

- It must print `OK`; it also catches accidental code changes in the English edition.

To confirm that "only comments changed, not behavior":

```bash
git diff -U0 -- nixos-infect.sh \
  | grep -E '^[+-][^+-]' \
  | grep -vE '^[+-][[:space:]]*(#|$)'
```

- Empty output means the change is only comments and blank lines, which is equivalent to an identical diff with comments stripped.
- When there is output, justify each line of code change; do not reformat the whole file with a formatting tool.

## Testing strategy

- Without a spare server, start with `--dry-run`: it only generates configuration into `/tmp/nixos-infect-dryrun` and does not change the system.
- `--no-infect`: stops right after writing `/etc/nix/nix.conf`, which validates dependencies and preflight without installing Nix.
- `--no-reboot`: installs fully without rebooting, so you can inspect `/etc/NIXOS_LUSTRATE`, the profile, and the configuration, then reboot by hand.
- A local container only goes as far as the probing/configuration stages (`--dry-run`); do not verify booting or disk takeover inside a container.
- Use `curl ... | bash -s -- --lang=zh` to verify that non-TTY runs do not read stdin; test interactive paths in a real terminal.
- Verify behavior changes on at least one KVM + BIOS cloud host, and feed the result back into the "verified platforms" table in the README.
- Mark unverified platforms (EFI, shared-kernel virtualization) explicitly and do not claim support for them.

```bash
bash nixos-infect.sh --dry-run --lang=zh
grep -R '@@' /tmp/nixos-infect-dryrun || echo "no placeholders"
```

## Documentation conventions

- Chinese is primary and English secondary; `docs/zh-CN/` and `docs/en/` match one to one in file names and heading levels.
- One file has exactly one `#`; `##` sections and `###` subsections, with no skipped levels.
- No long paragraphs: at most 3 lines each; use `-` lists for parallel items and tables for flags, matrices, and comparisons.
- Commands go in bash code blocks (fenced as `bash`), Nix configuration as `nix`, directory trees and flows as `text`.
- Open with 1-2 lines on "what problem this solves" and end with a fixed `## Related documentation`.
- Link sibling files as `./xxx.md`, screenshots as `../../screenshots/xxx.png`, and the README as `../../README.md`.
- Screenshots are PNG, at most 2000px wide and 100KB each; quantize them to a 256-color palette, and show them side by side in a README table that links to the full image.
- Keep each file between 80 and 200 lines; do not copy large parts of the README, summarize and link instead.
- Behavior changes update the README, the CLI docs, and the relevant guides together; interface changes also update `screenshots/`.

## Commit and release

- Commit prefixes: `docs:` documentation, `fix:` bug fixes, `feat:` features, `chore:` maintenance; for example `fix: invalidate the host boot cache`.
- The version number equals the date (such as `2026-10-01`) and appears in the script constants, the first line of `--help`, and the README table.
- Pre-release checklist:
  - `bash -n` and `shellcheck` report no new warnings.
  - The English edition is in sync and `bash scripts/verify-comment-parity.sh` prints OK.
  - `--dry-run` output has no `@@` placeholders, and `configuration.nix` parses with `nix-instantiate --parse`.
  - Changes affecting install or boot were verified on a real KVM host, and the platform table was updated.
  - Flags, defaults, and paths agree across the README, `docs/zh-CN`, and `docs/en`.
  - `LICENSE` stays GPLv3, and the upstream origin and acknowledgements are not lost.
  - Screenshots match the actual interface.

## How to extend

| Extension | Location | Must be updated in sync |
| --- | --- | --- |
| New mirror | `MIRRORS` and the probe paths in `SECTION 6` | README mirror table, fallback order, `--prefer` validation |
| New flag | `parse_args` and `show_help` in `SECTION 10` (defaults live in `SECTION 1`) | Full flag reference in the README, `cli.md` |
| Changed comments | `nixos-infect.sh` and `nixos-infect.en.sh` | Keep both in sync and run `scripts/verify-comment-parity.sh` |
| New UI string | `MSG_EN` / `MSG_ZH` in `SECTION 2` | Every call site, non-TTY defaults |
| Changed default configuration | Built-in templates in `SECTION 11` | `cfg_render` arguments in `SECTION 7`, placeholder docs |
| New placeholder | `SECTION 11` templates plus the render call in `SECTION 7` | README placeholder table, configuration docs |

- For a new mirror, confirm the three resource types first: installer, channel, and binary cache; a mirror without an installer can only serve the latter two.
- A new flag needs the environment variable (when applicable) and `--help` updated as well, and must have a deterministic default for non-TTY runs.

## Related documentation

- [README](../../README.md)
- [How it works](./how-it-works.md)
- [Configuration](./configuration.md)
