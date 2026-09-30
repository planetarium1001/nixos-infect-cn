#!/usr/bin/env bash
# ===========================================================================
# nixos-infect-cn 2026-09-30
# ---------------------------------------------------------------------------
# 使用国内镜像源在 Debian/Ubuntu 云主机覆盖安装 NixOS 
# fork 自 https://github.com/elitak/nixos-infect
#
# 用法:
#   curl -fsSL <url> | bash
#   bash nixos-infect.sh [OPTIONS]
#
# 详见 --help。
# ===========================================================================
set -o pipefail
umask 0022

# ===========================================================================
# SECTION 1: 常量与全局默认值
# ===========================================================================

# 版本号-日期
NIXOS_INFECT_CN_VERSION="2026-09-30"

# --- 用户可预置（环境变量不会被脚本重置） ---
LANG_OPT="${LANG_OPT:-en}"
VERBOSE="${VERBOSE:-0}"
MODE="${MODE:-auto}"                    # auto | interactive
ASSUME_YES="${ASSUME_YES:-0}"
FAST_MODE="${FAST_MODE:-0}"             # 测速 1 轮
SKIP_PROBE="${SKIP_PROBE:-0}"           # 复用缓存或保底顺序
NO_PROBE="${NO_PROBE:-0}"               # 完全不探测，直接用保底顺序
PREFER_MIRROR="${PREFER_MIRROR:-}"
NIX_CHANNEL="${NIX_CHANNEL:-}"
NIX_INSTALL_URL="${NIX_INSTALL_URL:-}"
NIX_CHANNEL_URL="${NIX_CHANNEL_URL:-}"
NIX_SUBSTITUTERS="${NIX_SUBSTITUTERS:-}"
NO_REBOOT="${NO_REBOOT:-}"
NO_SWAP="${NO_SWAP:-}"
NO_INFECT="${NO_INFECT:-}"
FORCE_NETWORKING="${FORCE_NETWORKING:-}"  # 1=强制, 0=强制不生成, ""=自动

# --- 路径（脚本内部，可被环境变量覆盖） ---
CONFIG_DIR="${CONFIG_DIR:-/etc/nixos}"
LOG_FILE="${LOG_FILE:-/var/log/nixos-infect.log}"
PROBE_CACHE="${PROBE_CACHE:-/tmp/nixos-infect-cn.probe}"
CLEANUP_SCRIPT="/root/nixos-infect-cleanup.sh"
PROBE_CACHE_TTL=3600                    # 1 小时

# --- 运行时状态（脚本写，不读环境） ---
DRY_RUN="${DRY_RUN:-0}"
NO_COLOR="${NO_COLOR:-}"
doNetConf=""
zramswap="true"
swapcfg=""
esp=""
grubdev=""
rootfsdev=""
rootfstype=""

# --- 模板覆盖: TYPE → PATH ---
declare -A TEMPLATE_OVERRIDES=()

# ===========================================================================
# SECTION 1.1: 颜色
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
# SECTION 2: 日志与 i18n
# ===========================================================================

_LOG_DISABLED=""
_log_write() {
  [ -n "$LOG_FILE" ] || return 0
  if [ -z "$_LOG_DISABLED" ]; then
    # 先探测一次可写性：不可写就整体关掉，避免每条日志都打印重定向错误
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
  # 标题
  [title_summary]="Probe Summary"
  [title_interactive]="Interactive Configuration"
  [title_install]="Installation"
  # 通用
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
  # 探测
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
  # 配置
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
  # 安装
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
  # 清理
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

msg() {
  local key="$1"
  if [ "$LANG_OPT" = "zh" ]; then
    printf '%s' "${MSG_ZH[$key]:-${MSG_EN[$key]:-}}"
  else
    printf '%s' "${MSG_EN[$key]:-}"
  fi
}

msg_fmt() {
  local key="$1"; shift
  local template
  template=$(msg "$key")
  # -- 必须有：模板以 "-" 开头时（如 "--prefer=%s ..."）printf 会把它当成选项
  # shellcheck disable=SC2059
  printf -- "$template" "$@"
}

# ===========================================================================
# SECTION 3: UI 原语
# ===========================================================================

# 显示宽度：ASCII 1 列，CJK 2 列
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

# 键值对打印（按显示宽度对齐）
# 用法: print_kv "Label" "value" [target_width]
print_kv() {
  local key="$1" value="$2" target_width="${3:-22}"
  local kw pad spaces
  kw=$(display_width "$key")
  pad=$((target_width - kw)); [ "$pad" -lt 0 ] && pad=0
  spaces=$(printf '%*s' "$pad" '')
  printf "  %s%s: ${C_CYAN}%s${C_RESET}\n" "$key" "$spaces" "$value"
}

# 是否允许向用户提问。
# 关键：`curl | bash` 时 stdin 就是脚本自身的数据流，此时 read 会吞掉后面的
# 脚本文本，导致 bash 解析位置错乱。所以非 TTY 一律不读 stdin，直接用默认值。
ui_can_prompt() {
  [ -t 0 ]
}

# 单选
# 用法: ui_choose_one "标题" "提示" "默认key" "key|label" "key|label" ...
# 输出: 选中的 key（stdout）
# 注意：菜单和提示一律写到 stderr，stdout 上只允许出现选中的 key。
# 调用方是 `x=$(ui_choose_one ...)`，若菜单混进 stdout 会被一起捕获，
# 导致 key 变成一个多行字符串、查表查不到。
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

# 多选（逗号分隔序号，按顺序输出）
# 用法: ui_choose_multi "标题" "提示" "默认order(如1,2,3)" "key|label" ...
# 输出: 选中的 key 列表，空格分隔（stdout）
# 同样：菜单写 stderr，只有结果写 stdout。
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

confirm() {
  local prompt="$1" default="${2:-n}"
  local hint
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  # 非交互（curl | bash / 管道 / </dev/null）：不读 stdin，直接采用默认值
  if ! ui_can_prompt; then
    printf '%s %s %s\n' "$prompt" "$hint" "$(msg noninteractive)"
    [ "$default" = "y" ]
    return
  fi
  printf '%s %s ' "$prompt" "$hint"
  local ans
  read -r ans || ans=""
  # 与清理脚本用同一套判定：去掉所有空白并转小写，回车取默认值。
  # 只有 y / yes 算同意；n / no 以及任何无法识别的输入都算不同意。
  ans=$(printf '%s' "$ans" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  [ -z "$ans" ] && ans="$default"
  case "$ans" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

enter_shell() {
  # 非 TTY（curl | bash）时绝不能起 bash：它的 stdin 就是本脚本，
  # 会把脚本剩余内容当成命令重新执行一遍。
  # 返回 1 表示没能进入 shell，调用方必须据此跳出重试循环，否则会死循环。
  if ! ui_can_prompt; then
    log_warn "$(msg shell_no_tty)"
    return 1
  fi
  log_info "$(msg config_enter_shell)"
  (cd "$CONFIG_DIR" && bash) || true
  return 0
}

# ===========================================================================
# SECTION 4: 通用工具
# ===========================================================================

# 把 Nix 的一行输出压成适合单行进度显示的形式：
#   copying path '/nix/store/<32 位 hash>-<名字>' from '...'   ->  copying <名字>
#   building '/nix/store/<32 位 hash>-<名字>.drv'              ->  building <名字>
# store 路径的 basename 固定是「32 位 hash + '-' + 名字」，去掉前 33 个字符就是包名，
# 比原样截断可读得多。最后按可用宽度截断，避免在终端里折行。
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

# 执行一条耗时命令，把它的输出收进日志，终端只留一行实时进度。
#   - 默认：转轮 + 已用秒数 + 输出的最后一行（下载/构建到哪一步一眼能看到）
#   - VERBOSE=1：不拦截，原样透传所有输出
#   - stderr 不是终端时：不画转轮，避免把控制字符写进管道和日志
# 用法: run_quiet "描述" cmd [args...]
# 退出码与被执行命令一致。
run_quiet() {
  local label="$1"; shift
  local tmplog rc start elapsed line idx=0 spin='-\|/'

  # 被包装的都是非交互命令，stdin 一律钉在 /dev/null：
  # 否则在 `curl | bash` 下子进程可能把脚本自身的剩余内容读走。
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
      # 只读文件末尾 4KB；Nix 的下载进度用 \r 刷新，先转成换行再取最后一条
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

  # 完整输出落进日志文件（LOG_FILE 不可写时 _LOG_DISABLED 已置 1）
  if [ "${_LOG_DISABLED:-0}" != "1" ] && [ -n "$LOG_FILE" ]; then
    { echo "===== $(date '+%F %T') $label ====="; cat "$tmplog"; } \
      >> "$LOG_FILE" 2>/dev/null || true
  fi
  rm -f "$tmplog"
  return "$rc"
}

# 规范化 substituters：过滤 cache.nixos.org，去重
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

# 生成 configuration.nix 的 nix.settings.substituters 块（含选项名）
# 返回空字符串表示整块不生成（让 Nix 用默认）
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

# 解析最新稳定版 channel，失败则回退到 nixos-25.11
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
# SECTION 5: 系统探测
# ===========================================================================

isX86_64() { [ "$(uname -m)" = "x86_64" ]; }
isEFI()    { [ -d /sys/firmware/efi ]; }

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

prepare_sysinfo() {
  if isEFI; then
    esp="$(findESP)"
  else
    for grubdev in /dev/vda /dev/sda /dev/xvda /dev/nvme0n1; do
      [ -e "$grubdev" ] && break
    done
  fi

  rootfsdev=$(mount | grep "on / type" | awk '{print $1;}')
  rootfstype=$(df "$rootfsdev" --output=fstype 2>/dev/null | sed 1d)

  export USER="root"
  export HOME="/root"
}

checkExistingSwap() {
  local SWAPSHOW
  SWAPSHOW=$(swapon --show --noheadings --raw 2>/dev/null || echo "")
  zramswap=true
  swapcfg=""
  if [ -n "$SWAPSHOW" ]; then
    local SWAP_DEVICE="${SWAPSHOW%% *}"
    if [ "${SWAP_DEVICE#/dev/}" != "$SWAP_DEVICE" ]; then
      zramswap=false
      swapcfg="swapDevices = [ { device = \"${SWAP_DEVICE}\"; } ];"
      NO_SWAP=1
    fi
  fi
}

# 静态网络检测：有 IP + 网关 + 无 DHCP 痕迹 → 认为需要 networking.nix
sys_needs_networking_conf() {
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

  # DHCP 痕迹
  if [ -d /var/lib/dhcp ] && ls /var/lib/dhcp/*.leases >/dev/null 2>&1; then
    log_info "$(msg networking_skipped)"; return 1
  fi
  if [ -d /var/lib/dhcpcd ] && ls /var/lib/dhcpcd/*.lease >/dev/null 2>&1; then
    log_info "$(msg networking_skipped)"; return 1
  fi
  if ls /run/systemd/netif/leases/* >/dev/null 2>&1; then
    log_info "$(msg networking_skipped)"; return 1
  fi

  # 接口是否标记为 dynamic
  if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'dynamic'; then
    log_info "$(msg networking_skipped)"; return 1
  fi

  # 有 IPv4 地址 → 静态
  if ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet '; then
    log_info "$(msg networking_detected)"
    return 0
  fi

  log_info "$(msg networking_skipped)"
  return 1
}

# ===========================================================================
# SECTION 6: 镜像探测
# ===========================================================================

# 保底顺序: TUNA → NJU → BFSU → USTC → SJTUG
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
# 探测数据是否新鲜（用于 main 判断是否显示 report / interactive）
PROBE_DATA_FRESH=0

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

speed_color() {
  local bps="$1"
  if [ -z "$bps" ] || [ "$bps" = "0" ]; then echo "$C_DIM"
  elif [ "$bps" -ge 1048576 ] 2>/dev/null; then echo "$C_GREEN"
  elif [ "$bps" -ge 307200 ] 2>/dev/null; then echo "$C_YELLOW"
  else echo "$C_RED"; fi
}

fmt_speed() {
  local bps="$1"
  echo "$(speed_color "$bps")$(fmt_speed_raw "$bps")${C_RESET}"
}

is_ok() {
  case "$1" in
    200|301|302|303|307|308) return 0 ;;
    *) return 1 ;;
  esac
}

probe_all() {
  local entry name base known_install
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name base known_install <<< "$entry"

    # Install
    local found_install="" url code variant
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

    # 测速
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

pick_store_list() {
  local -a items=()
  local entry name
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    [ "${R_STORE_OK[$name]}" = "1" ] || continue
    items+=("${R_MIRROR_SPEED[$name]:-0}:$name")
  done
  [ ${#items[@]} -eq 0 ] && return
  printf '%s\n' "${items[@]}" | sort -t: -k1 -rn | cut -d: -f2
}

# 保底顺序（TUNA → NJU → BFSU → USTC → SJTUG）
probe_fallback() {
  log_warn "$(msg probe_fallback)"
  local ch="${NIX_CHANNEL:-nixos-25.11}"
  NIX_INSTALL_URL="https://mirrors.tuna.tsinghua.edu.cn/nix/latest/install"
  NIX_CHANNEL_URL="https://mirrors.tuna.tsinghua.edu.cn/nix-channels/${ch}"
  NIX_SUBSTITUTERS="https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store https://mirror.nju.edu.cn/nix-channels/store https://mirrors.bfsu.edu.cn/nix-channels/store https://mirrors.ustc.edu.cn/nix-channels/store https://mirror.sjtu.edu.cn/nix-channels/store"
}

# 从探测结果生成最终选择（不覆盖用户已预设的值）
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

probe_run() {
  command -v curl >/dev/null 2>&1 || { log_error "$(msg probe_no_curl)"; exit 1; }

  # --no-probe: 直接保底
  if [ "${NO_PROBE:-0}" = "1" ]; then
    [ -z "$NIX_CHANNEL" ] && NIX_CHANNEL="nixos-25.11"
    probe_fallback
    NIX_SUBSTITUTERS=$(normalize_substituters "$NIX_SUBSTITUTERS")
    return 0
  fi

  # --skip-probe: 先查缓存
  if [ "${SKIP_PROBE:-0}" = "1" ]; then
    if [ -f "$PROBE_CACHE" ]; then
      local mtime age
      mtime=$(stat -c %Y "$PROBE_CACHE" 2>/dev/null || stat -f %m "$PROBE_CACHE" 2>/dev/null || echo 0)
      age=$(( $(date +%s) - mtime ))
      # --prefer 是用户的显式意图，缓存里只有上一轮的最终 URL、没有完整测速表，
      # 无法据此重新排序，所以此时必须忽略缓存、重新探测，否则 --prefer 被静默吞掉。
      if [ "$age" -lt "$PROBE_CACHE_TTL" ] && [ -z "$PREFER_MIRROR" ]; then
        # 保存用户预设值，source 后恢复（不覆盖用户显式指定）
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
    # 用户同意 → 落到下方正常探测
  fi

  # 正常探测
  if [ -z "$NIX_CHANNEL" ]; then
    NIX_CHANNEL=$(resolve_channel)
    log_debug "resolved channel: $NIX_CHANNEL"
  fi

  log_step "$(msg probe_running)"
  probe_all
  PROBE_DATA_FRESH=1
  probe_pick

  # 规范化：过滤 cache.nixos.org
  NIX_SUBSTITUTERS=$(normalize_substituters "$NIX_SUBSTITUTERS")

  probe_cache_write
}

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
    # 默认序号（根据速度排序映射到展示序号）
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

  # ---------- 应用 ----------
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

  # 交互选择后刷新缓存
  probe_cache_write
}

# ===========================================================================
# SECTION 7: 模板渲染与配置流程
# ===========================================================================

# 渲染模板到文件
# 用法: cfg_render "type" "out" "KEY=value" "KEY=value" ...
#   type: configuration | hardware | networking
#   占位符: @@KEY@@ 会被替换为对应 value
#   若用户提供 --template=TYPE:PATH 覆盖，则使用外部模板
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
  for pair in "$@"; do
    tmpl="${tmpl//@@${pair%%=*}@@/${pair#*=}}"
  done

  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$tmpl" > "$out"
}

# 收集 SSH 公钥（过滤注释行，规范化格式）
cfg_collect_ssh_keys() {
  # 注意：这里用 raw_keys（字符串），不要与 ui_choose_* 里的 keys 数组同名
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

  local keys_nix="" line trimmed
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed 's/\r//g')
    trimmed=$(printf '%s' "$line" | xargs)
    [ -z "$trimmed" ] && continue
    keys_nix="${keys_nix}
    \"${trimmed}\""
  done <<< "$raw_keys"
  printf '%s' "$keys_nix"
}

# 计数（用于 config_summary）
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

  # networking（仅当需要时）
  if [ -n "$doNetConf" ]; then
    cfg_generate_networking
  fi
}

cfg_generate_networking() {
  local IFS=$'\n'
  local eth0_name eth0_ip4s eth0_ip6s gateway gateway6 ether0
  eth0_name=$(ip address show | grep '^2:' | awk -F': ' '{print $2}')
  eth0_ip4s=$(ip address show dev "$eth0_name" | grep 'inet ' | sed -r 's|.*inet ([0-9.]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|')
  eth0_ip6s=$(ip address show dev "$eth0_name" | grep 'inet6 ' | sed -r 's|.*inet6 ([0-9a-f:]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|' || true)
  gateway=$(ip route show dev "$eth0_name" | grep default | sed -r 's|default via ([0-9.]+).*|\1|')
  gateway6=$(ip -6 route show dev "$eth0_name" | grep default | sed -r 's|default via ([0-9a-f:]+).*|\1|' || true)
  ether0=$(ip address show dev "$eth0_name" | grep link/ether | sed -r 's|.*link/ether ([0-9a-f:]+) .*|\1|')

  # 强行指定 --networking 但取不到网卡时，宁可直接失败，也不要生成一份
  # 语法合法但字段为空的 networking.nix —— 那会导致重启后彻底失联。
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

# 从生成的 configuration.nix 回读一个 `key = "value"` 形式的值。
# 交互模式下用户可能手工改过配置，摘要必须按文件的实际内容显示，
# 否则会出现「改了 hostName 但摘要还显示旧值」这种误导。
cfg_file_get() {
  local key="$1" file="$CONFIG_DIR/configuration.nix"
  [ -r "$file" ] || return 0
  sed -n "s|^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*|\1|p" "$file" | head -1
}

# 回读 nix.settings.substituters 列表，返回空格分隔的 URL（形如脚本内的值）
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

config_summary() {
  local hn ch subs
  # 一律优先读文件，读不到才退回脚本内存里的值
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

config_flow() {
  local existing=0
  [ -e "$CONFIG_DIR/configuration.nix" ] && existing=1

  # 先决定 networking 策略
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
# SECTION 8: 安装与接管
# ===========================================================================

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

req() {
  type "$1" >/dev/null 2>&1 || command -v "$1" >/dev/null 2>&1
}

checkEnv() {
  [ "$(whoami)" = "root" ] || { log_error "Must run as root"; exit 1; }

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

makeSwap() {
  # 先清理上次可能残留的 swap 文件
  rm -f /tmp/nixos-infect.*.swp 2>/dev/null || true
  local swapFile
  swapFile=$(mktemp /tmp/nixos-infect.XXXXX.swp)
  dd if=/dev/zero "of=$swapFile" bs=1M count=1024 >/dev/null 2>&1
  chmod 0600 "$swapFile"
  mkswap "$swapFile" >/dev/null 2>&1
  swapon "$swapFile" >/dev/null 2>&1 || true
}

removeSwap() {
  swapoff -a >/dev/null 2>&1 || true
  rm -f /tmp/nixos-infect.*.swp 2>/dev/null || true
}

write_nix_conf() {
  log_step "$(msg install_write_conf)"
  mkdir -p /etc/nix

  local subs
  subs=$(normalize_substituters "$NIX_SUBSTITUTERS")

  local keys_line='trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY='

  {
    # 非空时才写 substituters 行
    [ -n "$subs" ] && echo "substituters = $subs"
    echo "$keys_line"
    # 保留用户原有其他配置行（剔除旧的 substituters / trusted-public-keys）
    [ -f /etc/nix/nix.conf ] && \
      grep -vE '^(substituters|trusted-public-keys)[[:space:]]*=' /etc/nix/nix.conf || true
  } > /etc/nix/nix.conf.new
  mv /etc/nix/nix.conf.new /etc/nix/nix.conf
  log_debug "nix.conf written, substituters=${subs:-<default>}"
}

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

  groupadd nixbld -g 30000 2>/dev/null || true
  local i
  for i in $(seq 1 10); do
    useradd -c "Nix build user $i" -d /var/empty -g nixbld -G nixbld -M -N -r \
      -s "$(command -v nologin || echo /usr/sbin/nologin)" "nixbld$i" 2>/dev/null || true
  done

  # 先把安装器脚本取下来再执行：这样 curl 的进度条和安装器自身的输出
  # 不会混在一起，两段各自有清晰的提示。
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

semantic_check_loop() {
  log_step "$(msg install_build)"
  local nixpkgs_path nixos_config_path
  nixpkgs_path="$(realpath "$HOME/.nix-defexpr/channels/nixos")"
  nixos_config_path="$CONFIG_DIR/configuration.nix"

  while :; do
    # 用 run_quiet 跑：终端能看到下载/构建到哪一步，完整输出同时落进日志。
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

finalize_nixos() {
  # 幂等守卫：接管标记已存在则跳过
  if [ -f /etc/NIXOS ]; then
    log_info "$(msg install_finalize_skip)"
    return 0
  fi

  log_step "$(msg install_finalize)"

  rm -fv /nix/var/nix/profiles/default* >/dev/null 2>&1 || true
  /nix/var/nix/profiles/system/sw/bin/nix-collect-garbage >/dev/null 2>&1 || true

  if [ -L /etc/resolv.conf ]; then
    mv -v /etc/resolv.conf /etc/resolv.conf.lnk >/dev/null 2>&1 || true
    cat /etc/resolv.conf.lnk > /etc/resolv.conf 2>/dev/null || true
  fi

  touch /etc/NIXOS

  # 写入重启后清理脚本
  write_cleanup_script

  # LUSTRATE 追加 + 去重
  {
    echo etc/nixos
    echo etc/resolv.conf
    echo root/.nix-defexpr/channels
    echo root/nixos-infect-cleanup.sh
    (cd / && ls etc/ssh/ssh_host_*_key* 2>/dev/null || true)
  } >> /etc/NIXOS_LUSTRATE
  sort -u -o /etc/NIXOS_LUSTRATE /etc/NIXOS_LUSTRATE

  if isEFI; then
    rm -rf /boot.bak
    umount "$esp" 2>/dev/null || true
    mv -v /boot /boot.bak 2>/dev/null || {
      # 只有备份确实成功后才清空 /boot，否则宁可保留旧内容
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
    find /boot -depth ! -path /boot -exec rm -rf {} + 2>/dev/null || true
  fi

  # 引导程序安装（updating GRUB 2 menu / installing the GRUB 2 boot loader /
  # Installation finished）交给 run_quiet 收成一行，与其他步骤格式一致。
  if ! run_quiet "$(msg install_grub)" \
       /nix/var/nix/profiles/system/bin/switch-to-configuration boot; then
    log_error "$(msg install_grub_fail)"
    exit 1
  fi

  # 部分平台的宿主机（实测腾讯云部分镜像）自己解析 /boot/grub/grub.cfg 并直接
  # 引导，但会缓存解析结果，只有 /boot 下的内核文件发生变化时才重新读取。
  # 于是「改了 grub.cfg 也不生效」—— 重启后宿主机仍按旧的引导项启动原系统。
  # 动一下这些文件的时间戳即可让缓存失效，强制它重新解析。
  local kf
  for kf in /boot/vmlinuz-* /boot/initrd.img-*; do
    [ -e "$kf" ] || continue
    touch "$kf" 2>/dev/null || true
    log_debug "touched $kf to invalidate the host boot cache"
  done

  # 引导扇区（MBR / core.img / grub.cfg）刚写入，必须立刻落盘。
  # 脚本随后就会 reboot，如果还留在页缓存里，重启可能仍走旧的引导状态。
  sync
}

# ===========================================================================
# SECTION 9: 清理
# ===========================================================================

# 第一段：重启前
cleanup_pre_reboot() {
  # 兜底清理历史残留
  rm -f /tmp/nixos-infect.*.swp 2>/dev/null || true
  rm -f /etc/nix/nix.conf.bak 2>/dev/null || true
  # dry-run 目录：dry-run 模式下保留供用户查看
  if [ "${DRY_RUN:-0}" != "1" ] && [ -d /tmp/nixos-infect-dryrun ]; then
    rm -rf /tmp/nixos-infect-dryrun 2>/dev/null || true
  fi
  # PROBE_CACHE 刻意保留，供 --skip-probe 复用
}

# 第二段：写入重启后执行的清理脚本
write_cleanup_script() {
  cat > "$CLEANUP_SCRIPT" << 'CLEANUP_EOF'
#!/usr/bin/env bash
# ===========================================================================
# nixos-infect-cn — post-reboot cleanup
# 由 nixos-infect-cn 安装脚本写入。
# 重启进入 NixOS 并确认工作正常后执行本脚本，清理旧系统残留。
# ===========================================================================
set -euo pipefail

echo "=== nixos-infect-cn cleanup ==="

# 安全检查：确认当前确实已经引导进 NixOS。
# /run/current-system 只在 NixOS 引导后才存在，装完但还没重启的旧系统没有它。
if [ ! -e /run/current-system ] || ! grep -q '^ID=nixos$' /etc/os-release 2>/dev/null; then
  echo "ERROR: this does not look like a booted NixOS system." >&2
  echo "       Refusing to touch /old-root. Reboot into NixOS first." >&2
  exit 1
fi

# 1) 旧根文件系统（LUSTRATE 将原发行版移到 /old-root）
if [ -d /old-root ]; then
  echo ""
  echo "Old root filesystem detected at /old-root."
  echo "This contains the previous distribution's files."
  echo "If you have verified NixOS boots and runs correctly, it is safe to remove."
  # read 在 EOF 时会返回非零，set -e 下会直接终止脚本，
  # 导致后面的 GC 和自删都不执行；这里必须兜住。
  ans=""
  read -rp "Remove /old-root? [y/N] " ans || ans=""
  # 归一化：去掉所有空白并转小写，这样 " y "、"YES"、"Yes" 都能识别。
  # 只有 y / yes 才删除；回车、n / no，以及任何无法识别的输入一律保留。
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

# 2) EFI 场景：旧 /boot 备份
if [ -d /boot.bak ]; then
  echo "Removing /boot.bak ..."
  rm -rf /boot.bak
fi

# 3) Nix 垃圾回收
if command -v nix-collect-garbage >/dev/null 2>&1; then
  echo "Running nix-collect-garbage -d ..."
  nix-collect-garbage -d 2>/dev/null || true
fi

# 4) 自删除
# 只有 /old-root 真的清掉了才自删。否则保留脚本，方便之后再跑一次
# （用户这次选了「保留」，或删到一半失败，都应该还能重来）。
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
# SECTION 10: main + 参数解析
# ===========================================================================

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
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
        # 归一化为大写并校验，避免拼错时被静默忽略
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

main() {
  parse_args "$@"

  # dry-run 时输出到 /tmp，仅当用户没有显式设置 CONFIG_DIR
  if [ "${DRY_RUN:-0}" = "1" ]; then
    if [ "$CONFIG_DIR" = "/etc/nixos" ]; then
      CONFIG_DIR="/tmp/nixos-infect-dryrun"
    fi
    rm -rf "$CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"
    log_info "dry-run: output directory $CONFIG_DIR"
  fi

  log_step "$(msg title_install) [nixos-infect-cn $NIXOS_INFECT_CN_VERSION]"

  # 判断是否需要探测
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

  # 兜底填空
  [ -z "$NIX_CHANNEL" ] && NIX_CHANNEL=$(resolve_channel)
  [ -z "$NIX_INSTALL_URL" ] && NIX_INSTALL_URL="https://nixos.org/nix/install"
  [ -z "$NIX_CHANNEL_URL" ] && NIX_CHANNEL_URL="https://nixos.org/channels/$NIX_CHANNEL"

  # 规范化 substituters
  NIX_SUBSTITUTERS=$(normalize_substituters "$NIX_SUBSTITUTERS")

  # 系统信息
  prepare_sysinfo
  checkExistingSwap

  # 配置流程
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

  checkEnv

  if [ -z "$NO_SWAP" ] && [ "${zramswap:-true}" != "false" ]; then
    makeSwap
  fi

  write_nix_conf

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
    # 再兜一次：确保所有待写数据（含引导扇区）已经落盘再重启
    sync
    log_step "$(msg install_reboot)"
    reboot
  fi
}

# ===========================================================================
# SECTION 11: 内置模板
# ---------------------------------------------------------------------------
# 占位符 @@NAME@@ 由 cfg_render 替换。
# 用户可通过 --template=TYPE:PATH 覆盖。
# 直接编辑以下内容即可修改默认生成的配置。
# ===========================================================================

# --- configuration.nix ---
# shellcheck disable=SC2034  # 通过 cfg_render 的 ${!var} 间接引用
TMPL_CONFIGURATION=$(cat <<'TMPL_EOF'
{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    @@NETWORK_IMPORT@@
  ];

@@SUBSTITUTERS_BLOCK@@

  # nix-channel 也走国内镜像
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

  # 默认预装软件，按需调整
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
# shellcheck disable=SC2034  # 通过 cfg_render 的 ${!var} 间接引用
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
# shellcheck disable=SC2034  # 通过 cfg_render 的 ${!var} 间接引用
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

# --- networking.nix (仅在检测到静态网络时生成) ---
# shellcheck disable=SC2034  # 通过 cfg_render 的 ${!var} 间接引用
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
# 入口：只有直接运行时才调用 main（source 时不调用）
# 必须放在文件末尾 —— SECTION 11 的模板变量要先完成赋值。
#
# 三种运行方式：
#   ./nixos-infect.sh      BASH_SOURCE[0] == $0          → 运行
#   bash nixos-infect.sh   BASH_SOURCE[0] == $0          → 运行
#   curl ... | bash        BASH_SOURCE[0] 为空、$0=bash   → 运行
#   source nixos-infect.sh BASH_SOURCE[0] 非空且 != $0    → 不运行
# ===========================================================================
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
