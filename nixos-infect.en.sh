#!/usr/bin/env bash
# ===========================================================================
# nixos-infect-cn 2026-10-01 (English-comment edition of nixos-infect.sh)
# ---------------------------------------------------------------------------
# Overwrite-install NixOS on a cloud server running Debian / Ubuntu / OpenCloudOS, using China-based mirrors.
# Forked from https://github.com/elitak/nixos-infect
#
# Usage:
#   curl -fsSL <url> | bash -s -- --lang=zh   # piped run, non-interactive
#   bash nixos-infect.en.sh [OPTIONS]         # local run, supports --interactive
#
# Dependencies: bash 4+, curl (wget is used when curl is missing), awk, sed, tar, ip, bzcat, xzcat
# Entry point: main "$@" at the end of the file; sourcing this file runs nothing
# Docs: https://github.com/planetarium1001/nixos-infect-cn
#
# Reading and maintenance guide:
#   SECTION 1   Constants and global defaults   1.1 Colors
#   SECTION 2   Logging and i18n        SECTION 3   UI primitives
#   SECTION 4   Common utilities        SECTION 5   System probing
#   SECTION 6   Mirror probing          SECTION 7   Template rendering and config flow
#   SECTION 8   Install and takeover    SECTION 9   Cleanup
#   SECTION 10  main and argument parsing  SECTION 11  Built-in templates
#
# Conventions:
#   - Comments are aimed at maintainers and written in English (the canonical nixos-infect.sh uses Chinese); user-visible text goes through the MSG_* tables in SECTION 2
#   - New messages: add the key to both MSG_EN and MSG_ZH, then call msg / msg_fmt
#   - Function headers list purpose / usage / output / side effects; inline comments explain only "why"
#   - The script is idempotent by design: it can be run repeatedly, and finalize_nixos is skipped once the takeover is done
#   - Dangerous operations (wiping disks, writing the boot loader, rebooting) must have a fallback check; see the comments of each function
#
# Safety: this wipes the target machine's disk and overwrites the boot loader. Only run it on a disposable new machine.
# ===========================================================================

# Only pipefail is enabled on purpose: set -e is off because probing, package installation, and similar steps may fail,
# and the caller decides from the return value whether to abort; set -u is also off because earlier implementations rely on undefined variables being empty strings.
set -o pipefail
# Generated files are created as 644 (directories 755) so Nix and services can read the configuration.
umask 0022

# ===========================================================================
# SECTION 1: Constants and global defaults
# ---------------------------------------------------------------------------
# The single registry for global state:
# - Every user-presettable item is written as "${VAR:-default}", so environment variables are never reset by the script
# - Runtime state is written by the script; only DRY_RUN and NO_COLOR may be preset from the environment
# - Order for adding a switch: register it here -> parse it in parse_args -> sync --help and the documentation
# - User-visible text does not live here; it all goes into MSG_EN / MSG_ZH in SECTION 2
# ===========================================================================

# The version string is the release date and must match the README version table; update both when releasing.
NIXOS_INFECT_CN_VERSION="2026-10-01"

# --- User-presettable (environment variables are never reset by the script) ---
LANG_OPT="${LANG_OPT:-en}"
VERBOSE="${VERBOSE:-0}"
MODE="${MODE:-auto}"                    # auto | interactive
ASSUME_YES="${ASSUME_YES:-0}"
FAST_MODE="${FAST_MODE:-0}"             # 1 speed-test round
SKIP_PROBE="${SKIP_PROBE:-0}"           # reuse the cache or the fallback order
NO_PROBE="${NO_PROBE:-0}"               # no probing at all, use the fallback order directly
PREFER_MIRROR="${PREFER_MIRROR:-}"
NIX_CHANNEL="${NIX_CHANNEL:-}"
NIX_INSTALL_URL="${NIX_INSTALL_URL:-}"
NIX_CHANNEL_URL="${NIX_CHANNEL_URL:-}"
NIX_SUBSTITUTERS="${NIX_SUBSTITUTERS:-}"
NO_REBOOT="${NO_REBOOT:-}"
NO_SWAP="${NO_SWAP:-}"
NO_INFECT="${NO_INFECT:-}"
FORCE_NETWORKING="${FORCE_NETWORKING:-}"  # 1=force on, 0=force off, ""=auto

# --- Paths (internal, may be overridden by environment variables) ---
CONFIG_DIR="${CONFIG_DIR:-/etc/nixos}"
LOG_FILE="${LOG_FILE:-/var/log/nixos-infect.log}"
PROBE_CACHE="${PROBE_CACHE:-/tmp/nixos-infect-cn.probe}"
CLEANUP_SCRIPT="/root/nixos-infect-cleanup.sh"
PROBE_CACHE_TTL=3600                    # 1 hour

# --- Runtime state (written by the script, not read from the environment) ---
DRY_RUN="${DRY_RUN:-0}"
NO_COLOR="${NO_COLOR:-}"
doNetConf=""
zramswap="true"
swapcfg=""
esp=""
grubdev=""
rootfsdev=""
rootfstype=""

# --- Template overrides: TYPE → PATH ---
declare -A TEMPLATE_OVERRIDES=()

# ===========================================================================
# SECTION 1.1: Colors
# ---------------------------------------------------------------------------
# ANSI escapes are enabled only when writing to a terminal and color is not disabled.
# For pipes, redirections, and --no-color they are all empty, keeping logs and CI output plain text.
# ===========================================================================

if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';  C_DIM=$'\033[2m'
  C_RED=$'\033[31m';   C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m';  C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

# ===========================================================================
# SECTION 2: Logging and i18n
# ---------------------------------------------------------------------------
# Logging and messages are both centralized here:
# - Logging: colored by level on the terminal and also appended to LOG_FILE; when the file is not writable it degrades silently
# - Messages: the MSG_EN / MSG_ZH tables plus the msg / msg_fmt accessors
# - Convention: business code never hardcodes user-visible text; add a key first, then call msg
# ===========================================================================

# Master switch for file logging. The first failed write probe disables it permanently, so that each log line does not
# produce another redirection error (read-only file system, insufficient permissions, and similar cases).
_LOG_DISABLED=""
# Write one timestamped log line to LOG_FILE without printing to the terminal.
# Writability is probed before the first write; if it fails, file logging is disabled permanently (_LOG_DISABLED).
_log_write() {
  [ -n "$LOG_FILE" ] || return 0
  if [ -z "$_LOG_DISABLED" ]; then
    # Probe writability once: if it fails, turn file logging off entirely, so each log line does not print a redirection error
    if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
      _LOG_DISABLED=1
      return 0
    fi
  fi
  [ "$_LOG_DISABLED" = "1" ] && return 0
  local level="$1"; shift
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "----")
  printf '%s [%s] %s\n' "$ts" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Unified log entry points, by level:
#   log_info  normal progress (stdout)
#   log_warn  recoverable anomaly (stderr)
#   log_error fatal error (stderr)
#   log_step  phase heading (stdout, with the ==> prefix)
#   log_debug printed only with --verbose
# Unless disabled, every level is also appended to LOG_FILE.
log_info()  { printf '%s[INFO]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; _log_write INFO  "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; _log_write WARN  "$*"; }
log_error() { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; _log_write ERROR "$*"; }
log_step()  { printf '%s==>%s %s\n'     "$C_CYAN"   "$C_RESET" "$*"; _log_write STEP  "$*"; }
log_debug() {
  [ "$VERBOSE" = "1" ] || return 0
  printf '%s[DEBUG]%s %s\n' "$C_DIM" "$C_RESET" "$*"
  _log_write DEBUG "$*"
}

# ---------------------------------------------------------------------------
# i18n
# ---------------------------------------------------------------------------
declare -A MSG_EN=(
  # Headings
  [title_summary]="Probe Summary"
  [title_interactive]="Interactive Configuration"
  [title_install]="Installation"
  # Common
  [ok]="OK"
  [not_found]="NOT_FOUND"
  [official]="official"
  [default]="default"
  [noninteractive]="non-interactive"
  [default_order]="Default order"
  [hint_single]="single choice"
  [hint_multi]="multiple, ordered"
  [run_done]="%s: done in %ss"
  [run_failed]="%s: failed, last 30 lines below"
  # Probing
  [probe_no_curl]="Error: curl is required. Please install it first."
  [probe_running]="Probing mirrors, this may take a moment..."
  [probe_fallback]="Using fallback mirror order: TUNA, NJU, BFSU, USTC, SJTUG"
  [probe_cache_hit]="Reusing cached probe results (age: %s s)."
  [probe_cache_miss]="No probe cache found."
  [probe_cache_expired]="Probe cache expired (age: %s s), re-measuring."
  [probe_cache_ignored_prefer]="--prefer=%s given, ignoring probe cache and re-measuring."
  [probe_confirm_measure]="Run a fresh speed measurement now?"
  [footnote_speed]="Speed: 1MB range request on the Nix path (nixpkgs-unstable channel tarball), 3 rounds, median. Use --fast for 1 round."
  [footnote_untested_store]="OK = mirror reachable but speed not measurable (large Nix files blocked or unavailable)."
  [prompt_install]="Choose install mirror"
  [prompt_channel]="Choose channels mirror"
  [prompt_store]="Choose store order"
  # Configuration
  [config_existing]="Existing %s found"
  [config_existing_hint]="Choose how to proceed:"
  [config_choice_use]="Use it as-is and continue"
  [config_choice_review]="Review and edit in a shell"
  [config_choice_overwrite]="Overwrite with default configuration"
  [config_choice_prompt]="Choice"
  [config_summary_title]="Configuration summary"
  [config_summary_hostname]="Hostname"
  [config_summary_keys]="SSH authorized keys"
  [config_summary_channel]="NixOS channel"
  [config_summary_substituters]="Substituters"
  [config_summary_networking]="Networking config"
  [config_enter_shell]="Entering shell. Edit the files, then type 'exit' to return."
  [shell_no_tty]="No TTY available, cannot open an interactive shell. Please run the script locally to edit the configuration."
  [install_fix_config]="Configuration %s is invalid and no interactive shell is available. Fix it and re-run."
  [boot_backup_failed]="Failed to back up /boot to /boot.bak; aborting before touching /boot."
  [config_file]="Config file"
  [config_related]="Related files"
  [config_proceed]="Proceed with this configuration?"
  [config_review_again]="Re-opening shell for further edits."
  [config_generating]="Generating default configuration"
  [config_template_external]="Using external template for %s: %s"
  [config_template_builtin]="Using built-in template for %s"
  [networking_detected]="Static network configuration detected, will generate networking.nix"
  [networking_skipped]="DHCP detected, networking.nix will not be generated"
  [networking_forced_on]="networking.nix generation forced by --networking"
  [networking_forced_off]="networking.nix generation disabled by --no-networking"
  [networking_no_data]="Cannot read interface/IP address (name='%s'); refusing to generate an empty networking.nix"
  # Installation
  [install_nix]="Installing Nix"
  [install_nix_skip]="Nix already installed, skipping installer download"
  [install_nix_fetch]="Downloading the Nix installer"
  [install_nix_fetch_fail]="Failed to download the Nix installer"
  [install_channel]="Setting up channel"
  [install_channel_update]="Downloading channel"
  [install_parse_check]="Checking configuration.nix syntax"
  [install_parse_fail]="configuration.nix failed to parse"
  [install_parse_ok]="Syntax OK"
  [install_log_hint]="Full error written to"
  [install_write_conf]="Writing /etc/nix/nix.conf"
  [install_build]="Building system closure"
  [install_finalize]="Staging NixOS takeover"
  [install_grub]="Installing the boot loader"
  [install_grub_fail]="Boot loader installation failed; the machine may not boot NixOS"
  [install_finalize_skip]="System already taken over, skipping finalize"
  [install_done]="Installation complete"
  [install_reboot]="Rebooting into NixOS"
  [dry_run_done]="Dry run complete. No changes made."
  # Cleanup
  [cleanup_hint]="After rebooting into NixOS and confirming it works, run:"
)

declare -A MSG_ZH=(
  [title_summary]="探测结果汇总"
  [title_interactive]="交互式配置"
  [title_install]="安装"
  [ok]="OK"
  [not_found]="NOT_FOUND"
  [official]="官方"
  [default]="默认"
  [noninteractive]="非交互"
  [default_order]="默认顺序"
  [hint_single]="单选"
  [hint_multi]="多选，按优先级排序"
  [run_done]="%s：完成，用时 %s 秒"
  [run_failed]="%s：失败，末尾 30 行如下"
  [probe_no_curl]="错误：需要 curl，请先安装。"
  [probe_running]="正在探测镜像站，请稍候……"
  [probe_fallback]="使用保底镜像顺序：TUNA、NJU、BFSU、USTC、SJTUG"
  [probe_cache_hit]="复用缓存探测结果（%s 秒前）。"
  [probe_cache_miss]="未找到探测缓存。"
  [probe_cache_expired]="探测缓存已过期（%s 秒前），将重新测速。"
  [probe_cache_ignored_prefer]="已指定 --prefer=%s，忽略探测缓存并重新测速。"
  [probe_confirm_measure]="现在跑一次新的测速？"
  [footnote_speed]="速度：对 Nix 路径（nixpkgs-unstable channel 文件）发起 1MB range 请求，3 轮取中位数。--fast 可改为 1 轮。"
  [footnote_untested_store]="OK = 镜像站可达但无法测速（大文件被拒绝访问或不存在）。"
  [prompt_install]="选择 Install 镜像"
  [prompt_channel]="选择 Channels 镜像"
  [prompt_store]="选择 Store 顺序"
  [config_existing]="发现已存在的 %s"
  [config_existing_hint]="请选择处理方式："
  [config_choice_use]="直接使用，继续安装"
  [config_choice_review]="进入 shell 审查和修改"
  [config_choice_overwrite]="用默认配置覆盖"
  [config_choice_prompt]="选择"
  [config_summary_title]="配置摘要"
  [config_summary_hostname]="主机名"
  [config_summary_keys]="SSH 授权密钥"
  [config_summary_channel]="NixOS channel"
  [config_summary_substituters]="Substituters"
  [config_summary_networking]="网络配置"
  [config_enter_shell]="进入 shell。编辑文件后输入 exit 返回。"
  [shell_no_tty]="当前没有 TTY，无法打开交互式 shell。请改为在本地运行脚本后再编辑配置。"
  [install_fix_config]="配置 %s 有误，且当前无法打开交互式 shell。请修正后重新运行。"
  [boot_backup_failed]="备份 /boot 到 /boot.bak 失败，为避免破坏 /boot，已中止。"
  [config_file]="配置文件"
  [config_related]="相关文件"
  [config_proceed]="使用此配置继续？"
  [config_review_again]="重新打开 shell 继续修改。"
  [config_generating]="正在生成默认配置"
  [config_template_external]="使用外部模板 %s：%s"
  [config_template_builtin]="使用内置模板 %s"
  [networking_detected]="检测到静态网络配置，将生成 networking.nix"
  [networking_skipped]="检测到 DHCP，不生成 networking.nix"
  [networking_forced_on]="已通过 --networking 强制生成 networking.nix"
  [networking_forced_off]="已通过 --no-networking 禁止生成 networking.nix"
  [networking_no_data]="无法读取网卡或 IP 地址（name='%s'），拒绝生成空的 networking.nix"
  [install_nix]="安装 Nix"
  [install_nix_skip]="Nix 已安装，跳过安装器下载"
  [install_nix_fetch]="正在下载 Nix 安装器"
  [install_nix_fetch_fail]="下载 Nix 安装器失败"
  [install_channel]="配置 channel"
  [install_channel_update]="下载 channel"
  [install_parse_check]="检查 configuration.nix 语法"
  [install_parse_fail]="configuration.nix 语法错误"
  [install_parse_ok]="语法正确"
  [install_log_hint]="详细日志已写入"
  [install_write_conf]="写入 /etc/nix/nix.conf"
  [install_build]="构建系统闭包"
  [install_finalize]="准备 NixOS 接管"
  [install_grub]="安装引导程序"
  [install_grub_fail]="引导程序安装失败，机器可能无法启动 NixOS"
  [install_finalize_skip]="系统已被接管，跳过 finalize"
  [install_done]="安装完成"
  [install_reboot]="即将重启进入 NixOS"
  [dry_run_done]="Dry run 完成，未做任何改动。"
  [cleanup_hint]="重启进入 NixOS 并确认工作正常后，执行："
)

# Fetch the message for the current language: zh uses MSG_ZH, anything else uses MSG_EN.
# A missing key falls back to English, then to an empty string.
msg() {
  local key="$1"
  if [ "$LANG_OPT" = "zh" ]; then
    printf '%s' "${MSG_ZH[$key]:-${MSG_EN[$key]:-}}"
  else
    printf '%s' "${MSG_EN[$key]:-}"
  fi
}

# Format a message that takes arguments, passed according to printf rules.
# Note that printf -- is required, otherwise a message starting with "-" (such as "--prefer=%s")
# is parsed by printf as an option.
msg_fmt() {
  local key="$1"; shift
  local template
  template=$(msg "$key")
  # -- is required: when the template starts with "-" (e.g. "--prefer=%s ..."), printf treats it as an option
  # shellcheck disable=SC2059
  printf -- "$template" "$@"
}

# ===========================================================================
# SECTION 3: UI primitives
# ---------------------------------------------------------------------------
# The minimal primitives for an interactive UI; they carry no business logic and can be reused at any stage.
# Core constraint: content shown to the user goes to stderr, function results go to stdout —
# callers capture results with $(...), and mixing the two would corrupt the value.
# On a non-TTY (curl | bash) stdin is never read; see ui_can_prompt for the reason.
# ===========================================================================

# Display width: 1 column for ASCII, 2 columns for CJK.
# Prefer python3's east_asian_width for an exact calculation; without python3,
# estimate from the byte and character counts so menus and tables stay aligned in a pure shell environment.
display_width() {
  local text="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys, unicodedata
s = sys.argv[1]
w = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)
print(w)
' "$text" 2>/dev/null && return
  fi
  local bytes chars
  bytes=$(printf '%s' "$text" | LC_ALL=C wc -c | tr -d ' ')
  chars=$(printf '%s' "$text" | wc -m | tr -d ' ')
  if [ "$bytes" = "$chars" ]; then
    echo "$bytes"
  else
    echo $(( (bytes + chars) / 2 ))
  fi
}

# Print a centered title with a separator line above and below (fixed width of 48 columns).
# Use print_title for visual grouping; do not assemble separator lines by hand.
print_title() {
  local text="$1"
  local width=48
  local text_width pad right_pad line
  text_width=$(display_width "$text")
  pad=$(( (width - text_width) / 2 )); [ "$pad" -lt 0 ] && pad=0
  right_pad=$(( width - pad - text_width )); [ "$right_pad" -lt 0 ] && right_pad=0
  line=$(printf '─%.0s' $(seq 1 "$width"))
  printf "${C_DIM}%s${C_RESET}\n" "$line"
  printf "%*s${C_BOLD}${C_CYAN}%s${C_RESET}%*s\n" "$pad" "" "$text" "$right_pad" ""
  printf "${C_DIM}%s${C_RESET}\n" "$line"
}

# Print a key-value pair (aligned by display width) for grouped output such as the configuration summary.
# Usage: print_kv "Label" "value" [target_width]
# target_width is the column width before the value, default 22; an overlong key is not padded.
print_kv() {
  local key="$1" value="$2" target_width="${3:-22}"
  local kw pad spaces
  kw=$(display_width "$key")
  pad=$((target_width - kw)); [ "$pad" -lt 0 ] && pad=0
  spaces=$(printf '%*s' "$pad" '')
  printf "  %s%s: ${C_CYAN}%s${C_RESET}\n" "$key" "$spaces" "$value"
}

# Whether the script may prompt the user.
# Key point: with `curl | bash`, stdin is the script's own data stream, so read would swallow the
# remaining script text and derail bash's parse position. So a non-TTY never reads stdin and uses the default instead.
ui_can_prompt() {
  [ -t 0 ]
}

# Single choice
# Usage: ui_choose_one "title" "hint" "default_key" "key|label" "key|label" ...
# Output: the selected key (stdout)
# Note: the menu and prompts always go to stderr; only the selected key may appear on stdout.
# The caller is `x=$(ui_choose_one ...)`; if the menu leaked into stdout it would be captured too,
# turning the key into a multi-line string that no table lookup can find.
ui_choose_one() {
  local title="$1" hint="$2" default_key="$3"
  shift 3

  echo "${C_MAGENTA}[ ${title} ]${C_RESET} ${C_DIM}(${hint})${C_RESET}" >&2

  local -a keys=()
  local i=0 default_idx=1 item key label
  for item in "$@"; do
    i=$((i + 1))
    key="${item%%|*}"
    label="${item#*|}"
    keys+=("$key")
    printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-16s${C_RESET} %s\n" "$i" "$key" "$label" >&2
    [ "$key" = "$default_key" ] && default_idx=$i
  done

  if ! ui_can_prompt; then
    printf "%s ${C_YELLOW}(%s: %s)${C_RESET}\n" "$title" "$(msg noninteractive)" "$default_key" >&2
    printf '%s' "$default_key"
    return 0
  fi

  printf "%s [1-%d] ${C_YELLOW}(%s: %d)${C_RESET}: " \
    "$title" "${#keys[@]}" "$(msg default)" "$default_idx" >&2
  local choice
  read -r choice || choice=""
  [ -z "$choice" ] && choice="$default_idx"
  if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#keys[@]}" ]; then
    printf '%s' "${keys[$((choice - 1))]}"
  else
    printf '%s' "$default_key"
  fi
}

# Multiple choice (comma-separated indexes, output in the given order)
# Usage: ui_choose_multi "title" "hint" "default_order (e.g. 1,2,3)" "key|label" ...
# Output: the list of selected keys, space-separated (stdout)
# Same rule: the menu goes to stderr, only the result goes to stdout.
ui_choose_multi() {
  local title="$1" hint="$2" default_order_in="$3"
  shift 3

  echo "${C_MAGENTA}[ ${title} ]${C_RESET} ${C_DIM}(${hint})${C_RESET}" >&2

  local -a keys=()
  local i=0 item key label
  for item in "$@"; do
    i=$((i + 1))
    key="${item%%|*}"
    label="${item#*|}"
    keys+=("$key")
    printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-16s${C_RESET} %s\n" "$i" "$key" "$label" >&2
  done

  local order=""
  if ui_can_prompt; then
    printf "%s ${C_YELLOW}(%s: %s)${C_RESET}: " \
      "$title" "$(msg default_order)" "$default_order_in" >&2
    read -r order || order=""
  else
    printf "%s ${C_YELLOW}(%s: %s)${C_RESET}\n" \
      "$title" "$(msg noninteractive)" "$default_order_in" >&2
  fi
  [ -z "$order" ] && order="$default_order_in"

  local out="" token
  while IFS= read -r token; do
    token=$(printf '%s' "$token" | tr -d ' ')
    [ -z "$token" ] && continue
    if [ "$token" -ge 1 ] 2>/dev/null && [ "$token" -le "${#keys[@]}" ]; then
      out="$out ${keys[$((token - 1))]}"
    fi
  done <<< "$(printf '%s' "$order" | tr ',' '\n')"
  printf '%s' "${out# }"
}

# Ask y/n; returning 0 means yes.
# On a non-TTY (piped run) stdin is not read and the default is returned, so the script text is not swallowed.
confirm() {
  local prompt="$1" default="${2:-n}"
  local hint
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  # Non-interactive (curl | bash / pipe / </dev/null): do not read stdin, use the default
  if ! ui_can_prompt; then
    printf '%s %s %s\n' "$prompt" "$hint" "$(msg noninteractive)"
    [ "$default" = "y" ]
    return
  fi
  printf '%s %s ' "$prompt" "$hint"
  local ans
  read -r ans || ans=""
  # Same matching as the cleanup script: strip all whitespace, lowercase, and Enter takes the default.
  # Only y / yes count as yes; n / no and any unrecognized input count as no.
  ans=$(printf '%s' "$ans" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  [ -z "$ans" ] && ans="$default"
  case "$ans" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

# Open an interactive shell in CONFIG_DIR so the user can edit the configuration files.
# Returning 0 means the shell was actually entered; returning 1 means there is no TTY, and the caller must then
# leave the retry loop, otherwise a non-interactive environment loops forever.
enter_shell() {
  # Never start bash on a non-TTY (curl | bash): its stdin is this very script,
  # so it would re-execute the remaining script content as commands.
  # Returning 1 means no shell was entered; the caller must break out of the retry loop or it loops forever.
  if ! ui_can_prompt; then
    log_warn "$(msg shell_no_tty)"
    return 1
  fi
  log_info "$(msg config_enter_shell)"
  # Change directory in a subshell so the script's own cwd is unaffected after exit.
  (cd "$CONFIG_DIR" && bash) || true
  return 0
}

# ===========================================================================
# SECTION 4: Common utilities
# ---------------------------------------------------------------------------
# General-purpose capabilities unrelated to the installation flow:
# - fmt_progress_line / run_quiet: condense long command output into a single progress line
# - normalize_substituters / subs_nix_block: normalization and rendering of cache URLs
# - resolve_channel: resolve the latest stable channel
# ===========================================================================

# Condense one line of Nix output into a form suitable for single-line progress:
#   copying path '/nix/store/<32-char hash>-<name>' from '...'   ->  copying <name>
#   building '/nix/store/<32-char hash>-<name>.drv'              ->  building <name>
# The basename of a store path is always "32-char hash + '-' + name", so dropping the first 33 characters gives the package name,
# which is far more readable than truncating the raw path. Finally truncate to the available width to avoid wrapping in the terminal.
fmt_progress_line() {
  local line="$1" max="$2" p
  case "$line" in
    "copying path '"*)
      p="${line#copying path \'}"; p="${p%%\'*}"
      p="${p##*/}"; [ "${#p}" -gt 33 ] && p="${p:33}"
      line="copying $p"
      ;;
    "building '"*)
      p="${line#building \'}"; p="${p%%\'*}"
      p="${p##*/}"; [ "${#p}" -gt 33 ] && p="${p:33}"
      line="building $p"
      ;;
  esac
  if [ "${#line}" -gt "$max" ] && [ "$max" -gt 3 ]; then
    line="${line:0:$((max - 3))}..."
  fi
  printf '%s' "$line"
}

# Run a slow command, capture its output into the log, and leave a single live progress line on the terminal.
#   - Default: spinner + elapsed seconds + last output line (shows at a glance where the download/build is)
#   - VERBOSE=1: no interception, all output is passed through as-is
#   - When stderr is not a terminal: no spinner, so control characters are not written into pipes and logs
# Usage: run_quiet "description" cmd [args...]
# The exit code matches the executed command.
run_quiet() {
  local label="$1"; shift
  local tmplog rc start elapsed line idx=0 spin='-\|/'

  # The wrapped commands are all non-interactive, so stdin is always pinned to /dev/null:
  # otherwise under `curl | bash` a child process could read away the remaining content of the script itself.
  if [ "$VERBOSE" = "1" ]; then
    "$@" </dev/null
    return $?
  fi

  tmplog=$(mktemp) || { "$@" </dev/null; return $?; }
  start=$(date +%s)
  "$@" >"$tmplog" 2>&1 </dev/null &
  local pid=$!

  if [ -t 2 ]; then
    local cols
    cols=$(tput cols 2>/dev/null)
    [ -z "$cols" ] && cols=${COLUMNS:-80}
    while kill -0 "$pid" 2>/dev/null; do
      elapsed=$(( $(date +%s) - start ))
      idx=$(( (idx + 1) % 4 ))
      # Read only the last 4KB of the file; Nix refreshes download progress with \r, so convert it to newlines and take the last entry
      line=$(tail -c 4096 "$tmplog" 2>/dev/null | tr '\r' '\n' \
             | grep -v '^[[:space:]]*$' | tail -n 1)
      [ -z "$line" ] && line="$label"
      line=$(fmt_progress_line "$line" $((cols - 16)))
      printf '\r\033[K  %s  %ss  %s' "${spin:$idx:1}" "$elapsed" "$line" >&2
      sleep 1
    done
    printf '\r\033[K' >&2
  fi

  wait "$pid"; rc=$?
  elapsed=$(( $(date +%s) - start ))

  if [ "$rc" = "0" ]; then
    log_info "$(msg_fmt run_done "$label" "$elapsed")"
  else
    log_error "$(msg_fmt run_failed "$label")"
    tail -n 30 "$tmplog" >&2 2>/dev/null || true
  fi

  # The full output goes into the log file (_LOG_DISABLED is already 1 when LOG_FILE is not writable)
  if [ "${_LOG_DISABLED:-0}" != "1" ] && [ -n "$LOG_FILE" ]; then
    { echo "===== $(date '+%F %T') $label ====="; cat "$tmplog"; } \
      >> "$LOG_FILE" 2>/dev/null || true
  fi
  rm -f "$tmplog"
  return "$rc"
}

# Normalize substituters: space-separated input, space-separated output.
# Filter out cache.nixos.org — Nix appends it at the end automatically as a fallback,
# so writing it into the configuration would only duplicate it. Duplicates are removed and the user's order is kept.
normalize_substituters() {
  local raw="$1"
  local out=""
  local -A seen=()
  local url
  for url in $raw; do
    case "$url" in
      "https://cache.nixos.org"|"https://cache.nixos.org/") continue ;;
    esac
    [ "${seen[$url]:-}" = "1" ] && continue
    seen[$url]=1
    out="$out $url"
  done
  printf '%s' "${out# }"
}

# Generate the nix.settings.substituters block for configuration.nix (option name included).
# An empty return value means the whole block is omitted and Nix uses its default caches.
# The caller passes the return value into the template as @@SUBSTITUTERS_BLOCK@@.
subs_nix_block() {
  local subs
  subs=$(normalize_substituters "$NIX_SUBSTITUTERS")
  [ -z "$subs" ] && return
  printf '  nix.settings.substituters = [\n'
  local IFS=' '
  local url
  for url in $subs; do
    printf '    "%s"\n' "$url"
  done
  printf '  ];\n'
}

# Resolve the latest stable channel:
#   1. NIX_CHANNEL is already set → use it directly
#   2. --no-probe → no network access, use the built-in fallback
#   3. Read the nixos.org/channels/ page and take the stable version with the highest number
# If parsing fails or there is no network, fall back to nixos-25.11 so the flow can continue.
resolve_channel() {
  [ -n "$NIX_CHANNEL" ] && { printf '%s' "$NIX_CHANNEL"; return; }

  if [ "${NO_PROBE:-0}" = "1" ]; then
    printf '%s' "nixos-25.11"
    return
  fi

  local html latest
  html=$(curl -sL --connect-timeout 5 --max-time 10 \
    "https://nixos.org/channels/" 2>/dev/null || echo "")
  if [ -n "$html" ]; then
    latest=$(printf '%s' "$html" \
      | grep -oE 'nixos-[0-9]+\.[0-9]+' \
      | grep -v -- '-small' \
      | grep -v 'unstable' \
      | sort -V -u \
      | tail -1)
  fi

  if [ -n "${latest:-}" ]; then
    printf '%s' "$latest"
  else
    printf '%s' "nixos-25.11"
  fi
}
# ===========================================================================
# SECTION 5: System detection
# ---------------------------------------------------------------------------
# Read-only probe of the current boot mode, root device, swap and network shape,
# the results feed template rendering in SECTION 7. None of it changes during installation, so it is collected once up front.
# ===========================================================================

# Small platform helpers.
# isX86_64: whether to add x86-only kernel modules such as vmw_pvscsi.
# isEFI: presence of /sys/firmware/efi means treat the machine as EFI.
isX86_64() { [ "$(uname -m)" = "x86_64" ]; }
isEFI()    { [ -d /sys/firmware/efi ]; }

# Locate the EFI system partition (ESP); the result goes into global esp.
# Tries /boot/EFI, /boot/efi and /boot in turn, accepting only directories that are themselves mount points,
# then resolves a UUID device path through /dev/disk/by-uuid (more stable than /dev/sda1
# and matching NixOS hardware-configuration.nix conventions).
# Returns 1 when nothing is found; callers should treat it as a broken EFI environment.
findESP() {
  esp=""
  local d
  for d in /boot/EFI /boot/efi /boot; do
    [ ! -d "$d" ] && continue
    if [ "$d" = "$(df "$d" --output=target 2>/dev/null | sed 1d)" ]; then
      esp="$(df "$d" --output=source 2>/dev/null | sed 1d)"
      break
    fi
  done
  [ -z "$esp" ] && { echo "WARNING: No ESP mount point found" >&2; return 1; }
  local uuid
  for uuid in /dev/disk/by-uuid/*; do
    [ "$(readlink -f "$uuid")" = "$esp" ] && { echo "$uuid"; return 0; }
  done
}

# Collect boot mode and root filesystem info into globals:
#   EFI  → esp (probed by findESP)
#   BIOS → grubdev (tries vda / sda / xvda / nvme0n1 in order)
#   both paths fill rootfsdev and rootfstype
# Also pins USER / HOME to root so leftovers from sudo or su do not
# skew nix install paths and profile locations.
prepare_sysinfo() {
  if isEFI; then
    esp="$(findESP)"
  else
    for grubdev in /dev/vda /dev/sda /dev/xvda /dev/nvme0n1; do
      [ -e "$grubdev" ] && break
    done
  fi

  # Device and fstype are read separately: mount gives the device, df gives the fstype.
  rootfsdev=$(mount | grep "on / type" | awk '{print $1;}')
  rootfstype=$(df "$rootfsdev" --output=fstype 2>/dev/null | sed 1d)

  export USER="root"
  export HOME="/root"
}

# Check whether block-device swap already exists:
#   - yes → disable zram, write swapDevices into the hardware template, set NO_SWAP=1
#   - no  → keep zramSwap enabled and create temporary swap during installation as needed
checkExistingSwap() {
  local SWAPSHOW
  SWAPSHOW=$(swapon --show --noheadings --raw 2>/dev/null || echo "")
  zramswap=true
  swapcfg=""
  if [ -n "$SWAPSHOW" ]; then
    local SWAP_DEVICE="${SWAPSHOW%% *}"
    # Only block-device swap counts; virtual devices such as zram are not written to the hardware config.
    if [ "${SWAP_DEVICE#/dev/}" != "$SWAP_DEVICE" ]; then
      zramswap=false
      swapcfg="swapDevices = [ { device = \"${SWAP_DEVICE}\"; } ];"
      NO_SWAP=1
    fi
  fi
}

# Decide whether networking.nix is needed:
#   1. explicit --networking / --no-networking wins
#   2. no default route → not needed (DHCP case)
#   3. DHCP lease or dynamic flag found → not needed
#   4. static IPv4 address → needed
# A wrong call is costly (a bad config loses connectivity), so only unambiguous signals count.
sys_needs_networking_conf() {
  # Explicit flags win over automatic detection.
  if [ "$FORCE_NETWORKING" = "1" ]; then
    log_info "$(msg networking_forced_on)"
    return 0
  fi
  if [ "$FORCE_NETWORKING" = "0" ]; then
    log_info "$(msg networking_forced_off)"
    return 1
  fi

  local iface
  iface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  if [ -z "$iface" ]; then
    log_info "$(msg networking_skipped)"
    return 1
  fi

  # DHCP traces
  if [ -d /var/lib/dhcp ] && ls /var/lib/dhcp/*.leases >/dev/null 2>&1; then
    log_info "$(msg networking_skipped)"; return 1
  fi
  if [ -d /var/lib/dhcpcd ] && ls /var/lib/dhcpcd/*.lease >/dev/null 2>&1; then
    log_info "$(msg networking_skipped)"; return 1
  fi
  if ls /run/systemd/netif/leases/* >/dev/null 2>&1; then
    log_info "$(msg networking_skipped)"; return 1
  fi

  # Is the interface flagged dynamic
  if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'dynamic'; then
    log_info "$(msg networking_skipped)"; return 1
  fi

  # IPv4 address present → static
  if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
    log_info "$(msg networking_detected)"
    return 0
  fi

  log_info "$(msg networking_skipped)"
  return 1
}

# ===========================================================================
# SECTION 6: Mirror probing
# ---------------------------------------------------------------------------
# Installer, channel and binary cache are probed independently:
# - reachability via a HEAD request (is_ok)
# - speed sampled with a 1MB range request, median of several rounds
# - results go into the R_* associative arrays; probe_pick then derives the global URLs
# - user-set values have top priority; probing only fills the gaps
# ===========================================================================

# Fallback order: TUNA → NJU → BFSU → USTC → SJTUG
MIRRORS=(
  "TUNA|https://mirrors.tuna.tsinghua.edu.cn|/nix/latest/install"
  "NJU|https://mirror.nju.edu.cn|/nix/latest/install"
  "BFSU|https://mirrors.bfsu.edu.cn|/nix/latest/install"
  "USTC|https://mirrors.ustc.edu.cn|"
  "SJTUG|https://mirror.sjtu.edu.cn|"
)

INSTALL_VARIANTS=(
  "/nix/latest/install"
  "/nix/install"
  "/nix/nix-installer/latest/install"
)

CHANNEL_PATH="/nix-channels"
STORE_PATH="/nix-channels/store"
GENERIC_SPEED_PATH="/nix-channels/nixpkgs-unstable/nixexprs.tar.xz"

SPEED_ROUNDS=3
CONNECT_TIMEOUT=5
MAX_TIME=30
RANGE_BYTES=1048576
MIN_VALID_BYTES=262144

declare -A R_INSTALL_URL R_CHANNEL_URL R_STORE_URL
declare -A R_CHANNEL_OK R_STORE_OK
declare -A R_MIRROR_SPEED
# Whether probe data is fresh (main uses it to decide on report / interactive)
PROBE_DATA_FRESH=0

# Fetch a URL's HTTP status code, retrying once on failure.
# 000 (unreachable) and 5xx (gateway/service trouble) are usually transient and worth a retry;
# other codes are returned as-is for is_ok to judge.
probe_http() {
  local url="$1"
  local code
  code=$(curl -sI -o /dev/null -w "%{http_code}" \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" -L "$url" 2>/dev/null || echo "000")
  case "$code" in
    000|500|502|503|504)
      sleep 1
      code=$(curl -sI -o /dev/null -w "%{http_code}" \
        --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" -L "$url" 2>/dev/null || echo "000")
      ;;
  esac
  echo "$code"
}

# Issue a 1MB range request for a URL and print "<seconds> <bytes/sec>".
# 1MB is enough to separate fast from slow without stalling long on a slow mirror.
# If the actual download is under MIN_VALID_BYTES, return "0 0": the mirror blocks range
# requests or served an error page, so this round of speed testing is void.
speed_test_range() {
  local url="$1"
  local out
  out=$(curl -sL -r "0-$((RANGE_BYTES - 1))" -o /dev/null \
    --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" \
    -w "%{time_total} %{size_download} %{speed_download}" "$url" 2>/dev/null || echo "0 0 0")
  local t sz sp
  t=$(printf '%s' "$out" | awk '{print $1}')
  sz=$(printf '%s' "$out" | awk '{print $2}')
  sp=$(printf '%s' "$out" | awk '{print $3}')
  sz=${sz%%.*}
  if [ -z "$sz" ] || [ "$sz" -lt "$MIN_VALID_BYTES" ] 2>/dev/null; then
    echo "0 0"; return
  fi
  echo "$t $sp"
}

# Median over several speed rounds to damp jitter; --fast runs only one round.
# Returns 0 when all rounds fail. A median reflects a mirror's normal speed better than a mean.
speed_median() {
  local url="$1"
  local rounds="$SPEED_ROUNDS"
  [ "${FAST_MODE:-0}" = "1" ] && rounds=1

  local -a speeds=()
  local i out s
  for i in $(seq 1 "$rounds"); do
    out=$(speed_test_range "$url")
    s=$(printf '%s' "$out" | awk '{print $2}')
    s=${s%%.*}
    [ -n "$s" ] && [ "$s" -gt 0 ] 2>/dev/null && speeds+=("$s")
  done
  local n=${#speeds[@]}
  if [ "$n" -eq 0 ]; then echo "0"; return; fi
  printf '%s\n' "${speeds[@]}" | sort -n | awk -v n="$n" 'NR==int((n+1)/2){print $1}'
}

# Convert bytes/sec into human units: MB/s, KB/s, B/s.
# 0 or empty shows as "—", meaning no speed was measured.
fmt_speed_raw() {
  local bps="$1"
  if [ -z "$bps" ] || [ "$bps" = "0" ]; then
    echo "—"
  elif [ "$bps" -ge 1048576 ] 2>/dev/null; then
    awk -v b="$bps" 'BEGIN{printf "%.1f MB/s", b/1048576}'
  elif [ "$bps" -ge 1024 ] 2>/dev/null; then
    awk -v b="$bps" 'BEGIN{printf "%.0f KB/s", b/1024}'
  else
    echo "${bps} B/s"
  fi
}

# Pick a terminal color by speed for the probe result table:
#   ≥ 1 MB/s green, ≥ 300 KB/s yellow, otherwise red, 0 dim.
speed_color() {
  local bps="$1"
  if [ -z "$bps" ] || [ "$bps" = "0" ]; then echo "$C_DIM"
  elif [ "$bps" -ge 1048576 ] 2>/dev/null; then echo "$C_GREEN"
  elif [ "$bps" -ge 307200 ] 2>/dev/null; then echo "$C_YELLOW"
  else echo "$C_RED"; fi
}

# Combine color and unit for direct use in menus and summary tables.
fmt_speed() {
  local bps="$1"
  echo "$(speed_color "$bps")$(fmt_speed_raw "$bps")${C_RESET}"
}

# Whether an HTTP status code means the resource exists (common redirects included).
# Decides only whether it is fetchable, not the content.
is_ok() {
  case "$1" in
    200|301|302|303|307|308) return 0 ;;
    *) return 1 ;;
  esac
}

# Probe the three resource kinds per mirror, writing into the R_* associative arrays:
#   R_INSTALL_URL    installer address (known path first, then INSTALL_VARIANTS)
#   R_CHANNEL_OK/URL channel availability and address
#   R_STORE_OK/URL   binary cache availability and address
#   R_MIRROR_SPEED   overall speed in bytes/sec; 0 means reachable but unmeasurable
# The three kinds are independent: a mirror may offer channel but no installer.
# Speed uses the generic big file first, then falls back to the channel tarball, then the mirror root.
probe_all() {
  local entry name base known_install
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name base known_install <<< "$entry"

    # Install
    local found_install="" url code variant
    # When this mirror has a known installer path, try it first; a hit saves three variant probes.
    if [ -n "$known_install" ]; then
      url="${base}${known_install}"
      code=$(probe_http "$url")
      is_ok "$code" && found_install="$url"
    fi
    if [ -z "$found_install" ]; then
      for variant in "${INSTALL_VARIANTS[@]}"; do
        url="${base}${variant}"
        code=$(probe_http "$url")
        if is_ok "$code"; then found_install="$url"; break; fi
      done
    fi
    R_INSTALL_URL[$name]="${found_install}"

    # Channels
    local channel_url="${base}${CHANNEL_PATH}/${NIX_CHANNEL}"
    local channel_test_url="${channel_url}/nixexprs.tar.xz"
    code=$(probe_http "$channel_test_url")
    if is_ok "$code"; then
      R_CHANNEL_OK[$name]=1
      R_CHANNEL_URL[$name]="$channel_url"
    else
      R_CHANNEL_OK[$name]=0
      R_CHANNEL_URL[$name]=""
    fi

    # Store
    local store_url="${base}${STORE_PATH}"
    local store_test_url="${store_url}/nix-cache-info"
    code=$(probe_http "$store_test_url")
    if is_ok "$code"; then
      R_STORE_OK[$name]=1
      R_STORE_URL[$name]="$store_url"
    else
      R_STORE_OK[$name]=0
      R_STORE_URL[$name]=""
    fi

    # Speed
    local mirror_speed="0"
    local generic_url="${base}${GENERIC_SPEED_PATH}"
    local generic_code
    generic_code=$(probe_http "$generic_url")
    if is_ok "$generic_code"; then
      mirror_speed=$(speed_median "$generic_url")
    fi
    if [ "$mirror_speed" = "0" ] && [ "${R_CHANNEL_OK[$name]}" = "1" ]; then
      mirror_speed=$(speed_median "$channel_test_url")
    fi
    # When neither the generic file nor the channel tarball yields a speed, fall back to the mirror root; fast vs slow is all that matters.
    if [ "$mirror_speed" = "0" ] && [ "${R_STORE_OK[$name]}" = "1" ]; then
      local fallback_speed
      fallback_speed=$(speed_median "${base}/")
      if [ "$fallback_speed" != "0" ]; then
        mirror_speed="$fallback_speed"
      fi
    fi
    R_MIRROR_SPEED[$name]="$mirror_speed"
  done
}

# Pick the fastest mirror name for one resource kind (install / channel).
# Only mirrors with that kind available count; a zero-speed mirror can still win (better than none).
# Prints the mirror name, or an empty string when none is available.
pick_best() {
  local kind="$1" best_name="" best_speed=-1 entry name s
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    local available=0
    case "$kind" in
      install) [ -n "${R_INSTALL_URL[$name]}" ] && available=1 ;;
      channel) [ "${R_CHANNEL_OK[$name]}" = "1" ] && available=1 ;;
    esac
    [ "$available" = "1" ] || continue
    s="${R_MIRROR_SPEED[$name]:-0}"
    if [ "$s" -gt "$best_speed" ] 2>/dev/null; then
      best_speed="$s"; best_name="$name"
    fi
  done
  echo "$best_name"
}

# Prefer the mirror named by --prefer (provided that kind is really available),
# otherwise fall back to pick_best. A preference is not a guarantee: if unavailable, a faster mirror wins.
pick_with_preference() {
  local kind="$1"
  if [ -n "$PREFER_MIRROR" ]; then
    local preferred_ok=0
    case "$kind" in
      install) [ -n "${R_INSTALL_URL[$PREFER_MIRROR]:-}" ] && preferred_ok=1 ;;
      channel) [ "${R_CHANNEL_OK[$PREFER_MIRROR]:-}" = "1" ] && preferred_ok=1 ;;
    esac
    if [ "$preferred_ok" = "1" ]; then echo "$PREFER_MIRROR"; return; fi
  fi
  pick_best "$kind"
}

# Print every usable binary-cache mirror name, fastest first, one per line.
# Feeds probe_pick's substituters list and interactive mode's default order.
pick_store_list() {
  local -a items=()
  local entry name
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    [ "${R_STORE_OK[$name]}" = "1" ] || continue
    items+=("${R_MIRROR_SPEED[$name]:-0}:$name")
  done
  [ ${#items[@]} -eq 0 ] && return
  # The sort key is "speed:name"; only the name is printed.
  printf '%s\n' "${items[@]}" | sort -t: -k1 -rn | cut -d: -f2
}

# Fallback used when no probing happens at all (--no-probe, or probing skipped).
# Installer and channel are pinned to TUNA; the cache lists every mirror address.
# The cache order is only a "they all work" fallback, not measured speed.
probe_fallback() {
  log_warn "$(msg probe_fallback)"
  local ch="${NIX_CHANNEL:-nixos-25.11}"
  NIX_INSTALL_URL="https://mirrors.tuna.tsinghua.edu.cn/nix/latest/install"
  NIX_CHANNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/nix-channels/${ch}"
  NIX_SUBSTITUTERS="https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://mirror.nju.edu.cn/nix-channels/store https://mirrors.bfsu.edu.cn/nix-channels/store https://mirrors.ustc.edu.cn/nix-channels/store https://mirror.sjtu.edu.cn/nix-channels/store"
}

# Commit probe results to final values: NIX_INSTALL_URL / NIX_CHANNEL_URL / NIX_SUBSTITUTERS.
# All three follow one rule: never overwrite a user-set value, only fill gaps.
# When a resource kind is entirely unavailable, fall back to the official address.
probe_pick() {
  local best_install best_channel best_store
  best_install=$(pick_with_preference install)
  best_channel=$(pick_with_preference channel)
  best_store=$(pick_store_list)

  if [ -z "$NIX_INSTALL_URL" ]; then
    if [ -n "$best_install" ]; then
      NIX_INSTALL_URL="${R_INSTALL_URL[$best_install]}"
    else
      NIX_INSTALL_URL="https://nixos.org/nix/install"
    fi
  fi

  if [ -z "$NIX_CHANNEL_URL" ]; then
    if [ -n "$best_channel" ]; then
      NIX_CHANNEL_URL="${R_CHANNEL_URL[$best_channel]}"
    else
      NIX_CHANNEL_URL="https://nixos.org/channels/$NIX_CHANNEL"
    fi
  fi

  if [ -z "$NIX_SUBSTITUTERS" ]; then
    local subs="" name
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      [ -n "${R_STORE_URL[$name]}" ] || continue
      subs="$subs ${R_STORE_URL[$name]}"
    done <<< "$best_store"
    NIX_SUBSTITUTERS="${subs# }"
  fi
}

# Write this round's final results to the probe cache for --skip-probe to reuse within the TTL.
# Only results are recorded, not the full speed table — the cache saves time, not a probe run.
probe_cache_write() {
  mkdir -p "$(dirname "$PROBE_CACHE")"
  {
    echo "# nixos-infect-cn probe cache, $(date -Iseconds)"
    echo "NIX_INSTALL_URL='$NIX_INSTALL_URL'"
    echo "NIX_CHANNEL='$NIX_CHANNEL'"
    echo "NIX_CHANNEL_URL='$NIX_CHANNEL_URL'"
    echo "NIX_SUBSTITUTERS='$NIX_SUBSTITUTERS'"
  } > "$PROBE_CACHE"
}

# Mirror probing entry point, handling three cases in priority order:
#   1. --no-probe   → no requests at all; use the fallback order
#   2. --skip-probe → reuse a fresh cache; on --prefer conflict or expiry, ask and re-probe
#   3. default      → full probe
# On return NIX_CHANNEL / NIX_INSTALL_URL / NIX_CHANNEL_URL / NIX_SUBSTITUTERS
# are always set, so later stages need no empty checks.
probe_run() {
  command -v curl >/dev/null 2>&1 || { log_error "$(msg probe_no_curl)"; exit 1; }

  # --no-probe: straight to fallback
  if [ "${NO_PROBE:-0}" = "1" ]; then
    [ -z "$NIX_CHANNEL" ] && NIX_CHANNEL="nixos-25.11"
    probe_fallback
    NIX_SUBSTITUTERS=$(normalize_substituters "$NIX_SUBSTITUTERS")
    return 0
  fi

  # --skip-probe: check the cache first
  if [ "${SKIP_PROBE:-0}" = "1" ]; then
    if [ -f "$PROBE_CACHE" ]; then
      local mtime age
      mtime=$(stat -c %Y "$PROBE_CACHE" 2>/dev/null || stat -f %m "$PROBE_CACHE" 2>/dev/null || echo 0)
      age=$(( $(date +%s) - mtime ))
      # --prefer is explicit user intent, and the cache holds only the last round's final URLs, not a full speed table,
      # so it cannot be re-sorted; the cache must be ignored and probing redone here, or --prefer is silently swallowed.
      if [ "$age" -lt "$PROBE_CACHE_TTL" ] && [ -z "$PREFER_MIRROR" ]; then
        # Save user-preset values and restore them after source (never overwrite explicit ones)
        local _saved_install="$NIX_INSTALL_URL"
        local _saved_channel="$NIX_CHANNEL"
        local _saved_channel_url="$NIX_CHANNEL_URL"
        local _saved_subs="$NIX_SUBSTITUTERS"
        # shellcheck disable=SC1090
        source "$PROBE_CACHE"
        [ -n "$_saved_install" ]     && NIX_INSTALL_URL="$_saved_install"
        [ -n "$_saved_channel" ]     && NIX_CHANNEL="$_saved_channel"
        [ -n "$_saved_channel_url" ] && NIX_CHANNEL_URL="$_saved_channel_url"
        [ -n "$_saved_subs" ]        && NIX_SUBSTITUTERS="$_saved_subs"
        log_info "$(msg_fmt probe_cache_hit "$age")"
        return 0
      fi
      if [ "$age" -lt "$PROBE_CACHE_TTL" ]; then
        log_warn "$(msg_fmt probe_cache_ignored_prefer "$PREFER_MIRROR")"
      else
        log_warn "$(msg_fmt probe_cache_expired "$age")"
      fi
    else
      log_warn "$(msg probe_cache_miss)"
    fi
    if ! confirm "$(msg probe_confirm_measure)" y; then
      [ -z "$NIX_CHANNEL" ] && NIX_CHANNEL="nixos-25.11"
      probe_fallback
      NIX_SUBSTITUTERS=$(normalize_substituters "$NIX_SUBSTITUTERS")
      probe_cache_write
      return 0
    fi
    # User agreed → fall through to normal probing below
  fi

  # Normal probing
  if [ -z "$NIX_CHANNEL" ]; then
    NIX_CHANNEL=$(resolve_channel)
    log_debug "resolved channel: $NIX_CHANNEL"
  fi

  log_step "$(msg probe_running)"
  probe_all
  PROBE_DATA_FRESH=1
  probe_pick

  # Normalize: filter out cache.nixos.org
  NIX_SUBSTITUTERS=$(normalize_substituters "$NIX_SUBSTITUTERS")

  probe_cache_write
}

# Print the probe summary table: installer, channel and cache columns per mirror,
# plus speed footnotes. Only called when a real probe ran (PROBE_DATA_FRESH=1).
probe_report() {
  print_title "$(msg title_summary)"

  printf "${C_BOLD}%-8s %-14s %-14s %-14s${C_RESET}\n" "Mirror" "Install" "Channels" "Store"
  printf "${C_DIM}%-8s %-14s %-14s %-14s${C_RESET}\n" "------" "-------" "--------" "-----"

  local entry name
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"

    local speed="${R_MIRROR_SPEED[$name]:-0}"
    local c_sp
    if [ "$speed" = "0" ] || [ -z "$speed" ]; then c_sp="$C_DIM"; else c_sp=$(speed_color "$speed"); fi
    local speed_str
    speed_str=$(fmt_speed_raw "$speed")

    local c_inst txt_inst c_ch txt_ch c_st txt_st
    if [ -n "${R_INSTALL_URL[$name]}" ]; then
      c_inst="$c_sp"; txt_inst="$speed_str"
    else
      c_inst="$C_RED"; txt_inst="$(msg not_found)"
    fi

    if [ "${R_CHANNEL_OK[$name]}" = "1" ]; then
      c_ch="$c_sp"; txt_ch="$speed_str"
    else
      c_ch="$C_RED"; txt_ch="$(msg not_found)"
    fi

    if [ "${R_STORE_OK[$name]}" = "1" ]; then
      if [ "$speed" != "0" ] && [ -n "$speed" ]; then
        c_st="$c_sp"; txt_st="$speed_str"
      else
        c_st="$C_YELLOW"; txt_st="$(msg ok)"
      fi
    else
      c_st="$C_RED"; txt_st="$(msg not_found)"
    fi

    printf "${C_CYAN}%-8s${C_RESET} ${c_inst}%-14s${C_RESET} ${c_ch}%-14s${C_RESET} ${c_st}%-14s${C_RESET}\n" \
      "$name" "$txt_inst" "$txt_ch" "$txt_st"
  done
  echo ""

  local has_untested=0
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ "${R_STORE_OK[$name]}" = "1" ] && [ "${R_MIRROR_SPEED[$name]:-0}" = "0" ]; then
      has_untested=1
    fi
  done
  [ "$has_untested" = "1" ] && echo "${C_DIM}$(msg footnote_untested_store)${C_RESET}"
  echo "${C_DIM}$(msg footnote_speed)${C_RESET}"
  echo ""
}

# Mirror selection in interactive mode, three menus:
#   installer (single) → channel (single) → binary cache (multi, ordered by priority)
# Pressing Enter accepts the probe recommendation. The selection refreshes the probe cache.
probe_interactive() {
  if [ "${NO_PROBE:-0}" = "1" ] || [ "${#R_INSTALL_URL[@]}" -eq 0 ]; then
    log_debug "no probe data, skipping interactive mirror selection"
    return 0
  fi

  echo ""
  print_title "$(msg title_interactive)"
  echo ""

  local best_install best_channel best_store
  best_install=$(pick_with_preference install)
  best_channel=$(pick_with_preference channel)
  best_store=$(pick_store_list)

  # ---------- Install ----------
  local -a install_items=() name
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    [ -n "${R_INSTALL_URL[$name]}" ] || continue
    install_items+=("$name|$(fmt_speed "${R_MIRROR_SPEED[$name]:-0}")")
  done
  install_items+=("official|$(msg official)  https://nixos.org/nix/install")
  best_install=$(ui_choose_one "$(msg prompt_install)" "$(msg hint_single)" "$best_install" "${install_items[@]}")
  echo ""

  # ---------- Channels ----------
  local -a channel_items=()
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    [ "${R_CHANNEL_OK[$name]}" = "1" ] || continue
    channel_items+=("$name|$(fmt_speed "${R_MIRROR_SPEED[$name]:-0}")")
  done
  channel_items+=("official|$(msg official)  https://nixos.org/channels/${NIX_CHANNEL}")
  best_channel=$(ui_choose_one "$(msg prompt_channel)" "$(msg hint_single)" "$best_channel" "${channel_items[@]}")
  echo ""

  # ---------- Store ----------
  local -a store_items=()
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    [ "${R_STORE_OK[$name]}" = "1" ] || continue
    store_items+=("$name|$(fmt_speed "${R_MIRROR_SPEED[$name]:-0}")")
  done

  if [ "${#store_items[@]}" -eq 0 ]; then
    log_warn "No store mirror available, using default cache.nixos.org"
    best_store=""
  else
    # Default indices (speed order mapped to display indices)
    local default_order="" n idx
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      for idx in "${!store_items[@]}"; do
        if [ "${store_items[$idx]%%|*}" = "$n" ]; then
          if [ -z "$default_order" ]; then
            default_order="$((idx + 1))"
          else
            default_order="${default_order},$((idx + 1))"
          fi
        fi
      done
    done <<< "$best_store"

    local picked
    picked=$(ui_choose_multi "$(msg prompt_store)" "$(msg hint_multi)" "$default_order" "${store_items[@]}")
    best_store=$(printf '%s\n' "$picked" | tr ' ' '\n')
    echo ""
  fi

  # ---------- Apply ----------
  if [ -n "$best_install" ] && [ "$best_install" != "official" ]; then
    NIX_INSTALL_URL="${R_INSTALL_URL[$best_install]}"
  else
    NIX_INSTALL_URL="https://nixos.org/nix/install"
  fi

  if [ -n "$best_channel" ] && [ "$best_channel" != "official" ]; then
    NIX_CHANNEL_URL="${R_CHANNEL_URL[$best_channel]}"
  else
    NIX_CHANNEL_URL="https://nixos.org/channels/$NIX_CHANNEL"
  fi

  local subs="" n2
  while IFS= read -r n2; do
    [ -z "$n2" ] && continue
    [ -n "${R_STORE_URL[$n2]:-}" ] || continue
    subs="$subs ${R_STORE_URL[$n2]}"
  done <<< "$best_store"
  NIX_SUBSTITUTERS=$(normalize_substituters "${subs# }")

  # Refresh the cache after an interactive selection
  probe_cache_write
}

# ===========================================================================
# SECTION 7: Template rendering and configuration flow
# ---------------------------------------------------------------------------
# Render the SECTION 5 probe results and user choices into Nix files under /etc/nixos,
# and provide the "summary → human confirmation → edit shell" interactive flow.
# The output is the sole input to the SECTION 8 system closure build, so errors must surface here early.
# ===========================================================================

# Render a template to a file
# Usage: cfg_render "type" "out" "KEY=value" "KEY=value" ...
#   type: configuration | hardware | networking
#   placeholders: @@KEY@@ is replaced with the matching value
#   when the user passes --template=TYPE:PATH, the external template is used
cfg_render() {
  local type="$1" out="$2"
  shift 2

  local tmpl="" var=""

  if [ -n "${TEMPLATE_OVERRIDES[$type]:-}" ]; then
    local path="${TEMPLATE_OVERRIDES[$type]}"
    [ -r "$path" ] || { log_error "Template not readable: $path"; exit 1; }
    tmpl=$(cat "$path")
    log_info "$(msg_fmt config_template_external "$type" "$path")"
  else
    case "$type" in
      configuration) var="TMPL_CONFIGURATION" ;;
      hardware)
        if isEFI; then var="TMPL_HARDWARE_EFI"; else var="TMPL_HARDWARE_BIOS"; fi
        ;;
      networking) var="TMPL_NETWORKING" ;;
      *) log_error "Unknown template type: $type"; exit 1 ;;
    esac
    tmpl="${!var}"
    log_debug "$(msg_fmt config_template_builtin "$type")"
  fi

  local pair
  # Replace placeholders with bash parameter expansion instead of sed, so / and & in URLs are not special.
  for pair in "$@"; do
    tmpl="${tmpl//@@${pair%%=*}@@/${pair#*=}}"
  done

  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$tmpl" > "$out"
}

# Collect SSH public keys (drop comment lines, normalize the format)
cfg_collect_ssh_keys() {
  # Note: raw_keys is a string here; do not shadow the keys array used in ui_choose_*
  local raw_keys="" trypath
  local IFS=$'\n'
  for trypath in /root/.ssh/authorized_keys \
                  "/home/${SUDO_USER:-root}/.ssh/authorized_keys" \
                  "$HOME/.ssh/authorized_keys"; do
    if [ -r "$trypath" ]; then
      raw_keys=$(sed -E 's/^[^#].*[[:space:]]((sk-ssh|sk-ecdsa|ssh|ecdsa)-[^[:space:]]+)[[:space:]]+([^[:space:]]+)([[:space:]]*.*)$/\1 \3\4/' "$trypath")
      [ -n "$raw_keys" ] && break
    fi
  done

  # Wrap each public key as an indented Nix list item for direct @@AUTHORIZED_KEYS@@ replacement.
  local keys_nix="" line trimmed
  # Normalize line by line: strip CR and surrounding whitespace, skip empty lines.
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed 's/\r//g')
    trimmed=$(printf '%s' "$line" | xargs)
    [ -z "$trimmed" ] && continue
    keys_nix="${keys_nix}
    \"${trimmed}\""
  done <<< "$raw_keys"
  printf '%s' "$keys_nix"
}

# Count the authorized public keys that actually apply (skip comment lines) for the summary.
# Walks the same three candidate paths as cfg_collect_ssh_keys; prints 0 when none is found.
cfg_count_ssh_keys() {
  local kf count
  for kf in /root/.ssh/authorized_keys \
            "/home/${SUDO_USER:-root}/.ssh/authorized_keys" \
            "$HOME/.ssh/authorized_keys"; do
    if [ -r "$kf" ]; then
      count=$(grep -v '^#' "$kf" 2>/dev/null | grep -c . || true)
      count=$(printf '%s' "$count" | tr -d ' \n')
      count=${count:-0}
      if [ "$count" -gt 0 ] 2>/dev/null; then
        printf '%s' "$count"; return
      fi
    fi
  done
  printf '0'
}

# Render three configs into CONFIG_DIR:
#   configuration.nix            hostname / domain / zram / substituters / channel / public keys
#   hardware-configuration.nix   boot mode and filesystem (either EFI or BIOS)
#   networking.nix               generated only when doNetConf is non-empty
# All values come from the SECTION 5 probe results and the earlier user choices.
make_conf() {
  local akmods='"ata_piix" "uhci_hcd" "xen_blkfront"'
  isX86_64 && akmods="$akmods \"vmw_pvscsi\""

  log_step "$(msg config_generating)"

  local hostname_s domain_s
  hostname_s=$(hostname -s 2>/dev/null || echo "nixos")
  domain_s=$(hostname -d 2>/dev/null || echo "")

  local zram_val="true"
  [ "$zramswap" = "false" ] && zram_val="false"

  local network_import=""
  [ -n "$doNetConf" ] && network_import="./networking.nix # generated at runtime by nixos-infect"

  local subs_block keys_nix
  subs_block=$(subs_nix_block)
  keys_nix=$(cfg_collect_ssh_keys)

  cfg_render configuration "$CONFIG_DIR/configuration.nix" \
    "HOSTNAME=$hostname_s" \
    "DOMAIN=$domain_s" \
    "ZRAM=$zram_val" \
    "NETWORK_IMPORT=$network_import" \
    "SUBSTITUTERS_BLOCK=$subs_block" \
    "DEFAULT_CHANNEL=$NIX_CHANNEL_URL" \
    "AUTHORIZED_KEYS=$keys_nix"

  # hardware
  if isEFI; then
    cfg_render hardware "$CONFIG_DIR/hardware-configuration.nix" \
      "ESP=$esp" \
      "ROOTFSDEV=$rootfsdev" \
      "ROOTFSTYPE=$rootfstype" \
      "SWAPCFG=$swapcfg" \
      "AVAILABLE_KERNEL_MODULES=$akmods"
  else
    cfg_render hardware "$CONFIG_DIR/hardware-configuration.nix" \
      "GRUBDEV=$grubdev" \
      "ROOTFSDEV=$rootfsdev" \
      "ROOTFSTYPE=$rootfstype" \
      "SWAPCFG=$swapcfg" \
      "AVAILABLE_KERNEL_MODULES=$akmods"
  fi

  # networking (only when needed)
  if [ -n "$doNetConf" ]; then
    cfg_generate_networking
  fi
}

# Extract static network parameters from the current ip / resolv.conf and render networking.nix.
# Fail outright when no interface or IPv4 address is found: a networking.nix with
# empty fields cuts the rebooted machine off completely, far worse than aborting.
cfg_generate_networking() {
  local IFS=$'\n'
  local eth0_name eth0_ip4s eth0_ip6s gateway gateway6 ether0
  eth0_name=$(ip address show | grep '^2:' | awk -F': ' '{print $2}')
  eth0_ip4s=$(ip address show dev "$eth0_name" | grep 'inet ' | sed -r 's|.*inet ([0-9.]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|')
  eth0_ip6s=$(ip address show dev "$eth0_name" | grep 'inet6 ' | sed -r 's|.*inet6 ([0-9a-f:]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|' || true)
  gateway=$(ip route show dev "$eth0_name" | grep default | sed -r 's|default via ([0-9.]+).*|\1|')
  gateway6=$(ip -6 route show dev "$eth0_name" | grep default | sed -r 's|default via ([0-9a-f:]+).*|\1|' || true)
  ether0=$(ip address show dev "$eth0_name" | grep link/ether | sed -r 's|.*link/ether ([0-9a-f:]+) .*|\1|')

  # When --networking is forced but no interface is found, fail rather than emit a
  # syntactically valid networking.nix with empty fields — that loses connectivity after reboot.
  if [ -z "$eth0_name" ] || [ -z "$eth0_ip4s" ]; then
    log_error "$(msg_fmt networking_no_data "$eth0_name")"
    exit 1
  fi

  local nameservers
  nameservers=$(grep ^nameserver /etc/resolv.conf | sed -r \
    -e 's/^nameserver[[:space:]]+([0-9.a-fA-F:]+).*/"\1"/' \
    -e 's/127[0-9.]+/8.8.8.8/' \
    -e 's/::1/8.8.8.8/' | tr '\n' ' ')

  local predictable_inames="usePredictableInterfaceNames = lib.mkForce true;"
  case "$eth0_name" in eth*) predictable_inames="usePredictableInterfaceNames = lib.mkForce false;" ;; esac

  cfg_render networking "$CONFIG_DIR/networking.nix" \
    "ETH0_NAME=$eth0_name" \
    "ETH0_IP4S=$eth0_ip4s" \
    "ETH0_IP6S=$eth0_ip6s" \
    "GATEWAY=$gateway" \
    "GATEWAY6=$gateway6" \
    "ETHER0=$ether0" \
    "NAMESERVERS=$nameservers" \
    "PREDICTABLE_INAMES=$predictable_inames"
}

# Read back a `key = "value"`-style value from the generated configuration.nix.
# In interactive mode the user may have edited the config by hand, so the summary must show
# the file's actual contents, or it misleads (hostName changed, summary shows the old value).
cfg_file_get() {
  local key="$1" file="$CONFIG_DIR/configuration.nix"
  [ -r "$file" ] || return 0
  sed -n "s|^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*|\1|p" "$file" | head -1
}

# Read back the nix.settings.substituters list as space-separated URLs (the shape used in this script)
cfg_file_substituters() {
  local file="$CONFIG_DIR/configuration.nix"
  [ -r "$file" ] || return 0
  awk '
    /nix\.settings\.substituters[[:space:]]*=[[:space:]]*\[/ { inblk = 1; next }
    inblk && /\]/ { exit }
    inblk {
      sub(/^[[:space:]]*"/, ""); sub(/"[[:space:]]*$/, "")
      if ($0 != "") printf "%s ", $0
    }
  ' "$file"
}

# Print the configuration summary.
# Every field is read back from the generated files first (the user may have just edited them in the shell),
# falling back to in-script values only when unreadable.
config_summary() {
  local hn ch subs
  hn=$(cfg_file_get 'networking\.hostName')
  [ -z "$hn" ] && hn=$(hostname -s 2>/dev/null || echo unknown)

  ch=$(cfg_file_get 'system\.defaultChannel')
  ch="${ch##*/}"
  [ -z "$ch" ] && ch="$NIX_CHANNEL"

  subs=$(cfg_file_substituters)
  [ -z "$subs" ] && subs="$NIX_SUBSTITUTERS"

  echo ""
  print_title "$(msg config_summary_title)"
  print_kv "$(msg config_summary_hostname)"     "$hn"
  print_kv "$(msg config_summary_keys)"         "$(cfg_count_ssh_keys)"
  print_kv "$(msg config_summary_channel)"      "$ch"
  print_kv "$(msg config_summary_substituters)" "${subs% }"
  local net_status="DHCP"
  [ -n "$doNetConf" ] && net_status="static (networking.nix)"
  print_kv "$(msg config_summary_networking)"   "$net_status"
  echo ""
}

# Interactive "summary → confirm / edit" loop:
#   - each round shows the summary and file paths first
#   - confirmation returns; otherwise enter the shell to edit, then show the summary again
#   - --yes skips confirmation and returns immediately
edit_loop() {
  while :; do
    config_summary
    echo "  ${C_DIM}$(msg config_file): $CONFIG_DIR/configuration.nix${C_RESET}"
    echo "  ${C_DIM}$(msg config_related): $CONFIG_DIR/hardware-configuration.nix${C_RESET}"
    [ -n "$doNetConf" ] && echo "  ${C_DIM}$(msg config_related): $CONFIG_DIR/networking.nix${C_RESET}"
    echo ""

    if [ "$ASSUME_YES" != "1" ]; then
      if confirm "$(msg config_proceed)" y; then return 0; fi
      log_info "$(msg config_review_again)"
    else
      return 0
    fi
    enter_shell
  done
}

# Configuration stage driver:
#   - decide first whether to generate networking.nix (static IP detection, overridable by flags)
#   - /etc/nixos already configured: interactive offers three choices, auto reuses it
#   - otherwise generate the default config; interactive then enters the edit loop
config_flow() {
  local existing=0
  [ -e "$CONFIG_DIR/configuration.nix" ] && existing=1

  # Decide the networking strategy first
  if sys_needs_networking_conf; then doNetConf=1; else doNetConf=""; fi

  if [ "$existing" = "1" ]; then
    log_warn "$(msg_fmt config_existing "$CONFIG_DIR/configuration.nix")"
    if [ "$MODE" = "interactive" ]; then
      echo "$(msg config_existing_hint)"
      printf "  ${C_BOLD}1)${C_RESET} %s\n" "$(msg config_choice_use)"
      printf "  ${C_BOLD}2)${C_RESET} %s\n" "$(msg config_choice_review)"
      printf "  ${C_BOLD}3)${C_RESET} %s\n" "$(msg config_choice_overwrite)"
      printf "%s [1-3] ${C_YELLOW}(%s: 1)${C_RESET}: " "$(msg config_choice_prompt)" "$(msg default)"
      local choice
      read -r choice || choice=""
      [ -z "$choice" ] && choice=1
      case "$choice" in
        1)
          log_info "$(msg config_choice_use)"
          edit_loop
          return 0
          ;;
        2)
          enter_shell
          edit_loop
          return 0
          ;;
        3)
          log_warn "overwriting existing configuration"
          make_conf
          edit_loop
          return 0
          ;;
        *)
          log_warn "invalid choice, using existing"
          return 0
          ;;
      esac
    else
      log_info "auto mode: using existing configuration"
      return 0
    fi
  fi

  make_conf
  if [ "$MODE" = "interactive" ]; then
    edit_loop
  fi
}
# ===========================================================================
# SECTION 8: Install and takeover
# ---------------------------------------------------------------------------
# The part that actually modifies the system; the order must not be changed:
# preflight → temporary swap → nix.conf → install Nix → set up channel
# → syntax/semantic check → write LUSTRATE → install boot loader → sync
# A failure in a critical step exits right away, avoiding a half-installed state.
# ===========================================================================

# When curl is missing, define a curl function backed by wget and export it to child processes.
# Only covers the argument combinations this script uses (-fsSL -o / -O -L), not a general replacement;
# success is judged by the caller's return value.
fakeCurlUsingWget() {
  command -v wget >/dev/null 2>&1 || return 1
  curl() {
    eval "wget $(
      (local isStdout=1
      for arg in "$@"; do
        case "$arg" in
          "-o") echo "-O"; isStdout=0 ;;
          "-O") isStdout=0 ;;
          "-L") ;;
          *) echo "$arg" ;;
        esac
      done
      [ $isStdout -eq 1 ] && echo "-O-"
      ) | tr '\n' ' ')"
  }
  export -f curl
}

# Whether a command is available: functions and executables both count.
# Used for the unified missing-dependency checks in checkEnv.
req() {
  type "$1" >/dev/null 2>&1 || command -v "$1" >/dev/null 2>&1
}

# Pre-install preflight, bringing the system into a runnable state where possible:
#   - must be root, otherwise exit immediately
#   - fill in bzcat / xzcat / curl per distribution (failure is not fatal, req below is the fallback)
#   - abort when a critical command is missing, so the install cannot fail halfway
#   - tighten SSH host key permissions, NixOS-side sshd is strict about them
checkEnv() {
  [ "$(whoami)" = "root" ] || { log_error "Must run as root"; exit 1; }

  # Some distributions lack perl-Digest-SHA; try to install it first. Failure does not affect the checks below.
  if command -v dnf >/dev/null 2>&1; then dnf install -y perl-Digest-SHA >/dev/null 2>&1 || true; fi

  if ! command -v bzcat >/dev/null 2>&1; then
    if command -v yum >/dev/null 2>&1; then yum install -y bzip2 >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y bzip2 >/dev/null 2>&1 || true
    fi
  fi

  if ! command -v xzcat >/dev/null 2>&1; then
    if command -v yum >/dev/null 2>&1; then yum install -y xz xz-utils >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y xz-utils >/dev/null 2>&1 || true
    fi
  fi

  if ! command -v curl >/dev/null 2>&1; then
    fakeCurlUsingWget || true
    if ! command -v curl >/dev/null 2>&1; then
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y curl >/dev/null 2>&1 || true
      fi
    fi
  fi

  req curl || req wget || { log_error "Missing both curl and wget"; exit 1; }
  req bzcat            || { log_error "Missing bzcat";            exit 1; }
  req xzcat            || { log_error "Missing xzcat";            exit 1; }
  req groupadd         || { log_error "Missing groupadd";         exit 1; }
  req useradd          || { log_error "Missing useradd";          exit 1; }
  req ip               || { log_error "Missing ip";               exit 1; }
  req awk              || { log_error "Missing awk";              exit 1; }
  req tar              || { log_error "Missing tar";              exit 1; }

  if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    chmod 600 /etc/ssh/ssh_host_*_key
  fi
}

# Create and enable 1GB of temporary swap, relieving OOM when small-memory machines build the system closure.
# Fixed size: enough to cover the build peak, yet not enough to fill a small disk.
makeSwap() {
  # first clear any swap file left over from the previous run
  rm -f /tmp/nixos-infect.*.swp 2>/dev/null || true
  local swapFile
  swapFile=$(mktemp /tmp/nixos-infect.XXXXX.swp)
  dd if=/dev/zero "of=$swapFile" bs=1M count=1024 >/dev/null 2>&1
  chmod 0600 "$swapFile"
  mkswap "$swapFile" >/dev/null 2>&1
  swapon "$swapFile" >/dev/null 2>&1 || true
}

# Disable and delete the temporary swap file. The caller decides when to run this (with --no-swap it is never created).
removeSwap() {
  swapoff -a >/dev/null 2>&1 || true
  rm -f /tmp/nixos-infect.*.swp 2>/dev/null || true
}

# Write /etc/nix/nix.conf:
#   - write the domestic substituters; when empty omit the line and let Nix use the default
#   - pin trusted-public-keys, packages from domestic cache proxies are still verified by the official public key
#   - keep the user's other existing settings, dropping only the old substituters / trusted-public-keys
write_nix_conf() {
  log_step "$(msg install_write_conf)"
  mkdir -p /etc/nix

  local subs
  subs=$(normalize_substituters "$NIX_SUBSTITUTERS")

  local keys_line='trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY='

  {
    # write the substituters line only when non-empty
    [ -n "$subs" ] && echo "substituters = $subs"
    echo "$keys_line"
    # keep the user's other existing configuration lines (dropping the old substituters / trusted-public-keys)
    [ -f /etc/nix/nix.conf ] && \
      grep -vE '^(substituters|trusted-public-keys)[[:space:]]*=' /etc/nix/nix.conf || true
  } > /etc/nix/nix.conf.new
  mv /etc/nix/nix.conf.new /etc/nix/nix.conf
  log_debug "nix.conf written, substituters=${subs:-<default>}"
}

# Install Nix:
#   - if already present (e.g. script re-run), only source the environment variables and return
#   - create the nixbld group and build users first (installers on some mirrors do not)
#   - download the installer to a temporary file before running it, so the download progress bar and the installer output do not overwrite each other
#   - installer output goes through run_quiet into the log
install_nix() {
  if command -v nix >/dev/null 2>&1; then
    log_info "$(msg install_nix_skip)"
    if [ -f "$HOME/.nix-profile/etc/profile.d/nix.sh" ]; then
      # shellcheck disable=SC1090
      source "$HOME/.nix-profile/etc/profile.d/nix.sh" || true
    fi
    return 0
  fi

  log_step "$(msg install_nix)"

  # Pin gid=30000, matching upstream; when it already exists groupadd fails and that is ignored.
  groupadd nixbld -g 30000 2>/dev/null || true
  local i
  for i in $(seq 1 10); do
    useradd -c "Nix build user $i" -d /var/empty -g nixbld -G nixbld -M -N -r \
      -s "$(command -v nologin || echo /usr/sbin/nologin)" "nixbld$i" 2>/dev/null || true
  done

  # Fetch the installer script first, then run it: this way curl's progress bar and the
  # installer's own output do not interleave, and each stage has its own clear message.
  log_info "$(msg install_nix_fetch)"
  local installer
  installer=$(mktemp) || { log_error "$(msg install_nix_fetch_fail)"; exit 1; }
  if ! curl -fsSL -o "$installer" "$NIX_INSTALL_URL"; then
    log_error "$(msg install_nix_fetch_fail)"
    log_error "  $NIX_INSTALL_URL"
    rm -f "$installer"
    exit 1
  fi
  log_debug "installer downloaded from $NIX_INSTALL_URL"

  if ! run_quiet "$(msg install_nix)" sh "$installer" --no-channel-add; then
    rm -f "$installer"
    exit 1
  fi
  rm -f "$installer"

  # shellcheck disable=SC1090
  source "$HOME/.nix-profile/etc/profile.d/nix.sh" || {
    log_error "Failed to source nix profile"
    exit 1
  }
}

# Configure nix-channel: remove the official nixpkgs the installer may have added, point at the domestic channel and fetch it.
# The later evaluation of <nixpkgs/nixos> depends entirely on this step.
setup_channel() {
  log_step "$(msg install_channel)"

  nix-channel --remove nixpkgs 2>/dev/null || true
  if ! nix-channel --add "$NIX_CHANNEL_URL" nixos; then
    log_error "nix-channel --add failed: $NIX_CHANNEL_URL"
    exit 1
  fi
  if ! run_quiet "$(msg install_channel_update)" nix-channel --update; then
    exit 1
  fi
}

# Syntax check loop: continue only once nix-instantiate --parse succeeds.
# On failure, open a shell so the user can fix it in place; with no TTY exit immediately,
# never continuing the install with a broken configuration.nix.
parse_check_loop() {
  log_step "$(msg install_parse_check)"
  local config_path="$CONFIG_DIR/configuration.nix"
  while :; do
    local err
    if err=$(nix-instantiate --parse "$config_path" 2>&1 >/dev/null); then
      log_info "$(msg install_parse_ok)"
      return 0
    fi
    log_error "$(msg install_parse_fail)"
    {
      echo "===== $(date) parse error ====="
      echo "$err"
    } >> "$LOG_FILE" 2>/dev/null || true
    printf '%s %s\n' "$(msg install_log_hint)" "$LOG_FILE" >&2
    printf '%s\n' "$err" | head -20 >&2 || true
    enter_shell || { log_error "$(msg_fmt install_fix_config "$config_path")"; exit 1; }
  done
}

# Semantic check + building the system closure: evaluate configuration.nix and build it into
# /nix/var/nix/profiles/system; on success the new system is ready to switch to.
# On failure it likewise allows entering a shell to fix things and retry.
semantic_check_loop() {
  log_step "$(msg install_build)"
  local nixpkgs_path nixos_config_path
  # Specify both -I explicitly, so it does not depend on the current directory and stays stable on re-runs.
  nixpkgs_path="$(realpath "$HOME/.nix-defexpr/channels/nixos")"
  nixos_config_path="$CONFIG_DIR/configuration.nix"

  while :; do
    # Run through run_quiet: the terminal shows how far the download/build got, the full output also lands in the log.
    if run_quiet "$(msg install_build)" nix-env --set \
        -I "nixpkgs=$nixpkgs_path" \
        -I "nixos-config=$nixos_config_path" \
        -f '<nixpkgs/nixos>' \
        -p /nix/var/nix/profiles/system \
        -A system; then
      return 0
    fi
    printf '%s %s\n' "$(msg install_log_hint)" "$LOG_FILE" >&2
    enter_shell || { log_error "$(msg_fmt install_fix_config "$nixos_config_path")"; exit 1; }
  done
}

# Take over the system so the next boot enters NixOS. In order:
#   1. idempotent guard: /etc/NIXOS already exists means takeover happened, return immediately
#   2. clean up the installer profile, replace the /etc/resolv.conf symlink with a regular file
#   3. write the /etc/NIXOS marker and the post-reboot cleanup script
#   4. append the NIXOS_LUSTRATE entries (the original system is moved to /old-root)
#   5. on EFI, back up /boot and re-mount the ESP
#   6. switch-to-configuration boot installs the boot loader
#   7. touch the /boot kernel files to invalidate the host machine's boot cache
#   8. sync to flush to disk (the caller reboots afterwards)
finalize_nixos() {
  # idempotent guard: skip when the takeover marker already exists
  if [ -f /etc/NIXOS ]; then
    log_info "$(msg install_finalize_skip)"
    return 0
  fi

  log_step "$(msg install_finalize)"

  # Remove the default profile the installer left behind, so it does not appear in the boot menu alongside the new system profile.
  rm -fv /nix/var/nix/profiles/default* >/dev/null 2>&1 || true
  # Remove temporary profiles created during the install, shrinking the store after takeover.
  /nix/var/nix/profiles/system/sw/bin/nix-collect-garbage >/dev/null 2>&1 || true

  # On some systems resolv.conf is a symlink to a systemd-resolved stub whose target does not exist once NixOS takes over.
  if [ -L /etc/resolv.conf ]; then
    mv -v /etc/resolv.conf /etc/resolv.conf.lnk >/dev/null 2>&1 || true
    cat /etc/resolv.conf.lnk > /etc/resolv.conf 2>/dev/null || true
  fi

  # idempotent marker: on a re-run finalize_nixos uses it to skip the takeover steps.
  touch /etc/NIXOS

  # Write the post-reboot cleanup script
  write_cleanup_script

  # LUSTRATE decides which paths are kept from the old system into the new one after reboot:
  #   etc/nixos                    user configuration
  #   etc/resolv.conf              DNS (may still be needed during install)
  #   root/.nix-defexpr/channels   channel links
  #   root/nixos-infect-cleanup.sh the cleanup script itself
  #   etc/ssh/ssh_host_*_key*      host keys, keeping the SSH fingerprint unchanged
  {
    echo etc/nixos
    echo etc/resolv.conf
    echo root/.nix-defexpr/channels
    echo root/nixos-infect-cleanup.sh
    (cd / && ls etc/ssh/ssh_host_*_key* 2>/dev/null || true)
  } >> /etc/NIXOS_LUSTRATE
  # Deduplicate: a re-run, or identical entries already written upstream, must not leave duplicate paths in LUSTRATE.
  sort -u -o /etc/NIXOS_LUSTRATE /etc/NIXOS_LUSTRATE

  if isEFI; then
    rm -rf /boot.bak
    umount "$esp" 2>/dev/null || true
    mv -v /boot /boot.bak 2>/dev/null || {
      # wipe /boot only once the backup really succeeded; otherwise prefer keeping the old content
      if cp -a /boot /boot.bak; then
        rm -rf /boot/*
        umount /boot 2>/dev/null || true
      else
        log_error "$(msg boot_backup_failed)"
        exit 1
      fi
    }
    mkdir -p /boot
    mount "$esp" /boot
    # Wipe the freshly mounted ESP: the old distribution's /boot content is no longer needed, and leftover kernels can confuse boot.
    find /boot -depth ! -path /boot -exec rm -rf {} + 2>/dev/null || true
  fi

  # Boot loader installation (updating GRUB 2 menu / installing the GRUB 2 boot loader /
  # Installation finished) is collapsed into one line by run_quiet, consistent with the other steps.
  if ! run_quiet "$(msg install_grub)" \
       /nix/var/nix/profiles/system/bin/switch-to-configuration boot; then
    log_error "$(msg install_grub_fail)"
    exit 1
  fi

  # On some platforms the host machine (some Tencent Cloud images, as measured) parses /boot/grub/grub.cfg itself and
  # boots from it directly, but caches the parse result and re-reads it only when a kernel file under /boot changes.
  # So "editing grub.cfg has no effect" — after reboot the host machine still boots the original system from the stale entry.
  # Touching these files' timestamps invalidates the cache and forces it to parse again.
  local kf
  for kf in /boot/vmlinuz-* /boot/initrd.img-*; do
    [ -e "$kf" ] || continue
    touch "$kf" 2>/dev/null || true
    log_debug "touched $kf to invalidate the host boot cache"
  done

  # The boot sector (MBR / core.img / grub.cfg) was just written and must be flushed to disk at once.
  # The script reboots right after; if the data is still in the page cache, the reboot may still take the old boot state.
  sync
}

# ===========================================================================
# SECTION 9: Cleanup
# ---------------------------------------------------------------------------
# In two stages:
# - before reboot: delete install-time temporary files (the probe cache is deliberately kept)
# - after reboot: generate a cleanup script for the user to run manually
# Deleting the old system is irreversible, so the script deliberately stays "user-confirmed + re-runnable on failure".
# ===========================================================================

# Stage one: cleanup before reboot.
# Delete install-time temporary files and the nix.conf backup; the dry-run directory is kept for the user to inspect.
# PROBE_CACHE is deliberately kept for reuse by the next --skip-probe.
cleanup_pre_reboot() {
  # fallback cleanup of leftovers from earlier runs
  rm -f /tmp/nixos-infect.*.swp 2>/dev/null || true
  rm -f /etc/nix/nix.conf.bak 2>/dev/null || true
  # dry-run directory: kept in dry-run mode for the user to inspect
  if [ "${DRY_RUN:-0}" != "1" ] && [ -d /tmp/nixos-infect-dryrun ]; then
    rm -rf /tmp/nixos-infect-dryrun 2>/dev/null || true
  fi
}

# Stage two: generate the cleanup script the user runs manually after reboot, at /root/nixos-infect-cleanup.sh.
# The script content is written verbatim through a single-quoted heredoc, so no variables are expanded when generating it.
# The old system is an irreversible operation, so the cleanup script itself handles "self-check + confirmation + re-runnable".
write_cleanup_script() {
  cat > "$CLEANUP_SCRIPT" << 'CLEANUP_EOF'
#!/usr/bin/env bash
# ===========================================================================
# nixos-infect-cn — post-reboot cleanup
# Written by the nixos-infect-cn installer.
# Run this after rebooting into NixOS and confirming it works, to remove the previous system leftovers.
# ===========================================================================
set -euo pipefail

echo "=== nixos-infect-cn cleanup ==="

# Safety check: make sure we really booted into NixOS.
# /run/current-system only exists after NixOS boots; a freshly installed system that has not rebooted lacks it.
if [ ! -e /run/current-system ] || ! grep -q '^ID=nixos$' /etc/os-release 2>/dev/null; then
  echo "ERROR: this does not look like a booted NixOS system." >&2
  echo "       Refusing to touch /old-root. Reboot into NixOS first." >&2
  exit 1
fi

# 1) Old root filesystem (LUSTRATE moves the previous distribution to /old-root)
if [ -d /old-root ]; then
  echo ""
  echo "Old root filesystem detected at /old-root."
  echo "This contains the previous distribution's files."
  echo "If you have verified NixOS boots and runs correctly, it is safe to remove."
  # read returns non-zero on EOF, which would abort this script under set -e,
  # skipping the GC and self-removal below; swallow the failure here.
  ans=""
  read -rp "Remove /old-root? [y/N] " ans || ans=""
  # Normalize: strip all whitespace and lowercase, so " y ", "YES" and "Yes" all match.
  # Delete only on y / yes; Enter, n / no and anything unrecognized keep the directory.
  ans=$(printf '%s' "$ans" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  case "$ans" in
    y|yes)
      echo "Removing /old-root ..."
      rm -rf /old-root
      ;;
    *)
      echo "Kept /old-root."
      echo "Remove it later with: rm -rf /old-root"
      ;;
  esac
fi

# 2) EFI case: backup of the old /boot
if [ -d /boot.bak ]; then
  echo "Removing /boot.bak ..."
  rm -rf /boot.bak
fi

# 3) Nix garbage collection
if command -v nix-collect-garbage >/dev/null 2>&1; then
  echo "Running nix-collect-garbage -d ..."
  nix-collect-garbage -d 2>/dev/null || true
fi

# 4) Self-removal
# Remove this script only after /old-root is really gone; otherwise keep it so it can run again.
# (the user chose to keep it, or removal failed halfway; either way they can retry).
if [ -d /old-root ]; then
  echo "Keeping this script: /old-root is still present."
  echo "Re-run it later with: bash $0"
else
  echo "Removing this script ..."
  rm -f "$0"
fi

echo "=== Cleanup complete ==="
CLEANUP_EOF
  chmod +x "$CLEANUP_SCRIPT"
  log_debug "cleanup script written: $CLEANUP_SCRIPT"
}

# ===========================================================================
# SECTION 10: main + argument parsing
# ---------------------------------------------------------------------------
# Argument parsing, help text and main flow orchestration.
# The call order in main is the actual install order; argument parsing has no side effects, so it can be tested on its own.
# ===========================================================================

# Parse command-line arguments into the global switches; unknown arguments are reported and exit immediately.
#   - language aliases --lang=zh_CN / zh_TW normalize to zh
parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      # language aliases all normalize to en / zh.
      --lang=zh|--lang=zh_CN|--lang=zh_TW) LANG_OPT="zh" ;;
      --lang=en) LANG_OPT="en" ;;
      --verbose) VERBOSE=1 ;;
      --interactive) MODE="interactive" ;;
      --auto) MODE="auto" ;;
      --yes) ASSUME_YES=1 ;;
      --skip-probe) SKIP_PROBE=1 ;;
      --no-probe) NO_PROBE=1 ;;
      --fast) FAST_MODE=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-reboot) NO_REBOOT=1 ;;
      --no-swap) NO_SWAP=1 ;;
      --no-infect) NO_INFECT=1 ;;
      --networking) FORCE_NETWORKING=1 ;;
      --no-networking) FORCE_NETWORKING=0 ;;
      --prefer=*)
        # normalize to upper case and validate, so a typo is not silently ignored
        PREFER_MIRROR=$(printf '%s' "${arg#*=}" | tr 'a-z' 'A-Z')
        local _m _valid=0
        for _m in "${MIRRORS[@]}"; do
          [ "${_m%%|*}" = "$PREFER_MIRROR" ] && _valid=1
        done
        if [ "$_valid" != "1" ]; then
          log_error "Unknown mirror for --prefer: ${arg#*=} (expected: TUNA NJU BFSU USTC SJTUG)"
          exit 1
        fi
        ;;
      --channel=*) NIX_CHANNEL="${arg#*=}" ;;
      # template overrides go into an associative array; repeating the same type keeps the last one.
      --template=*)
        local spec="${arg#*=}"
        local type="${spec%%:*}"
        local path="${spec#*:}"
        case "$type" in
          configuration|hardware|networking) TEMPLATE_OVERRIDES[$type]="$path" ;;
          *) log_error "Unknown template type: $type (expected configuration|hardware|networking)"; exit 1 ;;
        esac
        ;;
      --no-color) NO_COLOR=1 ;;
      --help|-h) show_help; exit 0 ;;
      -*) log_error "Unknown option: $arg"; show_help; exit 1 ;;
    esac
  done
}

# Print the --help text.
# When adding or removing options, keep these in sync: this function, the README options table, the options reference under docs.
show_help() {
  printf 'nixos-infect-cn %s\n\n' "$NIXOS_INFECT_CN_VERSION"
  cat <<'USAGE'
Usage: nixos-infect.sh [OPTIONS]

Install NixOS on a domestic cloud instance using China-accessible mirrors.

General:
  --lang=en|zh             Output language (default: en)
  --interactive            Interactive mode: choose mirrors, edit config
  --auto                   Fully automatic (default)
  --yes                    Skip final confirmation
  --verbose                Show debug output
  --no-color               Disable colored output
  --help                   Show this help

Probe:
  --skip-probe             Reuse cached probe results if fresh;
                           otherwise ask before re-measuring
  --no-probe               Skip probing entirely, use fallback mirror order
  --fast                   Fast probe: 1 speed round per mirror
  --prefer=NAME            Prefer mirror (TUNA, NJU, BFSU, USTC, SJTUG)
  --channel=CHANNEL        NixOS channel (default: auto-detect)

Configuration:
  --template=TYPE:PATH     Override built-in template
                             TYPE = configuration | hardware | networking
                           Can be specified multiple times.
  --networking             Force generate networking.nix (static IP)
  --no-networking          Never generate networking.nix

Install:
  --dry-run                Probe + generate config only, do not install
  --no-infect              Prepare only, skip actual install
  --no-reboot              Do not reboot after install
  --no-swap                Do not create temporary swap

Environment:
  NIX_INSTALL_URL          Override installer URL
  NIX_CHANNEL              Override channel name
  NIX_CHANNEL_URL          Override channel URL
  NIX_SUBSTITUTERS         Space-separated substituter URLs
  CONFIG_DIR               Output directory (default: /etc/nixos)
  LOG_FILE                 Log file (default: /var/log/nixos-infect.log)
USAGE
}

# Main flow, the call order is the actual install order:
#   arguments → dry-run directory → probe → fallback values → system information → configuration
#   → environment preflight → temporary swap → nix.conf → install Nix → channel
#   → syntax/semantic check → takeover → cleanup → reboot
# Details that need user confirmation or are allowed to fail are handled by the called functions; main only expresses the order.
main() {
  parse_args "$@"

  # in dry-run, output to /tmp, but only when the user has not explicitly set CONFIG_DIR
  if [ "${DRY_RUN:-0}" = "1" ]; then
    if [ "$CONFIG_DIR" = "/etc/nixos" ]; then
      CONFIG_DIR="/tmp/nixos-infect-dryrun"
    fi
    rm -rf "$CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"
    log_info "dry-run: output directory $CONFIG_DIR"
  fi

  log_step "$(msg title_install) [nixos-infect-cn $NIXOS_INFECT_CN_VERSION]"

  # decide whether probing is needed
  local need_probe=0
  [ -z "$NIX_INSTALL_URL" ] && need_probe=1
  [ -z "$NIX_CHANNEL_URL" ] && need_probe=1
  [ -z "$NIX_CHANNEL" ] && need_probe=1

  if [ "$need_probe" = "1" ]; then
    probe_run
    if [ "$PROBE_DATA_FRESH" = "1" ]; then
      probe_report
      [ "$MODE" = "interactive" ] && probe_interactive
    fi
  fi

  # fallback fill-in
  [ -z "$NIX_CHANNEL" ] && NIX_CHANNEL=$(resolve_channel)
  [ -z "$NIX_INSTALL_URL" ] && NIX_INSTALL_URL="https://nixos.org/nix/install"
  [ -z "$NIX_CHANNEL_URL" ] && NIX_CHANNEL_URL="https://nixos.org/channels/$NIX_CHANNEL"

  # normalize substituters
  NIX_SUBSTITUTERS=$(normalize_substituters "$NIX_SUBSTITUTERS")

  # system information
  prepare_sysinfo
  checkExistingSwap

  # configuration flow
  config_flow

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_info "$(msg dry_run_done)"
    log_info "  Generated config: $CONFIG_DIR/"
    log_info "  NIX_INSTALL_URL=$NIX_INSTALL_URL"
    log_info "  NIX_CHANNEL=$NIX_CHANNEL"
    log_info "  NIX_CHANNEL_URL=$NIX_CHANNEL_URL"
    log_info "  NIX_SUBSTITUTERS=${NIX_SUBSTITUTERS:-<default>}"
    exit 0
  fi

  # The configuration is generated; only from here on do we run operations that modify the system.
  checkEnv

  if [ -z "$NO_SWAP" ] && [ "${zramswap:-true}" != "false" ]; then
    makeSwap
  fi

  write_nix_conf

  # --no-infect: prepare only (configuration, nix.conf, temporary swap), do not install Nix.
  if [ -n "$NO_INFECT" ]; then
    log_info "NO_INFECT set, skipping installation"
    if [ -z "$NO_SWAP" ] && [ "${zramswap:-true}" != "false" ]; then
      removeSwap
    fi
    exit 0
  fi

  install_nix
  setup_channel
  parse_check_loop
  semantic_check_loop
  finalize_nixos

  if [ -z "$NO_SWAP" ] && [ "${zramswap:-true}" != "false" ]; then
    removeSwap
  fi

  cleanup_pre_reboot

  log_info "$(msg install_done)"
  log_info "$(msg cleanup_hint)"
  log_info "  bash $CLEANUP_SCRIPT"

  if [ -z "$NO_REBOOT" ]; then
    # one more fallback: make sure all pending data (including the boot sector) is flushed before rebooting
    sync
    log_step "$(msg install_reboot)"
    reboot
  fi
}

# ===========================================================================
# SECTION 11: Built-in templates
# ---------------------------------------------------------------------------
# Placeholders @@NAME@@ are replaced by cfg_render.
# Users can override them with --template=TYPE:PATH.
# Edit the content below directly to change the default generated configuration.
# Note: this section holds template text only, no logic; placeholder names must match the
# cfg_render calls in SECTION 7, so change both places when adding a placeholder.
# ===========================================================================

# --- configuration.nix ---
# shellcheck disable=SC2034  # referenced indirectly through ${!var} in cfg_render
TMPL_CONFIGURATION=$(cat <<'TMPL_EOF'
{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    @@NETWORK_IMPORT@@
  ];

@@SUBSTITUTERS_BLOCK@@

  system.defaultChannel = "@@DEFAULT_CHANNEL@@";

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = @@ZRAM@@;
  networking.hostName = "@@HOSTNAME@@";
  networking.domain = "@@DOMAIN@@";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [
@@AUTHORIZED_KEYS@@
  ];
  system.stateVersion = "25.11";

  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    wget
    htop
    tmux
  ];
}
TMPL_EOF
)

# --- hardware-configuration.nix (EFI) ---
# shellcheck disable=SC2034  # referenced indirectly through ${!var} in cfg_render
TMPL_HARDWARE_EFI=$(cat <<'TMPL_EOF'
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  fileSystems."/boot" = { device = "@@ESP@@"; fsType = "vfat"; };

  boot.initrd.availableKernelModules = [ @@AVAILABLE_KERNEL_MODULES@@ ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = { device = "@@ROOTFSDEV@@"; fsType = "@@ROOTFSTYPE@@"; };
  @@SWAPCFG@@
}
TMPL_EOF
)

# --- hardware-configuration.nix (BIOS) ---
# shellcheck disable=SC2034  # referenced indirectly through ${!var} in cfg_render
TMPL_HARDWARE_BIOS=$(cat <<'TMPL_EOF'
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.loader.grub.device = "@@GRUBDEV@@";

  boot.initrd.availableKernelModules = [ @@AVAILABLE_KERNEL_MODULES@@ ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = { device = "@@ROOTFSDEV@@"; fsType = "@@ROOTFSTYPE@@"; };
  @@SWAPCFG@@
}
TMPL_EOF
)

# --- networking.nix (generated only when static networking is detected) ---
# shellcheck disable=SC2034  # referenced indirectly through ${!var} in cfg_render
TMPL_NETWORKING=$(cat <<'TMPL_EOF'
{ lib, ... }: {
  networking = {
    nameservers = [ @@NAMESERVERS@@ ];
    defaultGateway = "@@GATEWAY@@";
    defaultGateway6 = {
      address = "@@GATEWAY6@@";
      interface = "@@ETH0_NAME@@";
    };
    dhcpcd.enable = false;
    @@PREDICTABLE_INAMES@@
    interfaces = {
      @@ETH0_NAME@@ = {
        ipv4.addresses = [@@ETH0_IP4S@@];
        ipv6.addresses = [@@ETH0_IP6S@@];
        ipv4.routes = [ { address = "@@GATEWAY@@"; prefixLength = 32; } ];
        ipv6.routes = [ { address = "@@GATEWAY6@@"; prefixLength = 128; } ];
      };
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="@@ETHER0@@", NAME="@@ETH0_NAME@@"
  '';
}
TMPL_EOF
)

# ===========================================================================
# Entry point: call main only when run directly (not when sourced)
# Must be at the end of the file — the template variables in SECTION 11 must be assigned first.
#
# Three ways to run it:
#   ./nixos-infect.sh      BASH_SOURCE[0] == $0          → run
#   bash nixos-infect.sh   BASH_SOURCE[0] == $0          → run
#   curl ... | bash        BASH_SOURCE[0] empty, $0=bash → run
#   source nixos-infect.sh BASH_SOURCE[0] set and != $0  → do not run
# ===========================================================================
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
