#!/usr/bin/env bash
# ===== module: 00-base.sh =====
# 基础层：全局默认值、颜色、日志、i18n、显示宽度、通用输入
# 依赖: 无
# 暴露: log_*/msg/msg_fmt/display_width/print_title/confirm/enter_shell
# 副作用: 无

set -o pipefail
umask 0022

# ===========================================================================
# 版本和默认值
# ===========================================================================
NIXOS_INFECT_CN_VERSION="1.0.0"

LANG_OPT="${LANG_OPT:-en}"
VERBOSE="${VERBOSE:-0}"
MODE="${MODE:-auto}"
ASSUME_YES="${ASSUME_YES:-0}"
FAST_MODE="${FAST_MODE:-0}"
CHANNEL="${CHANNEL:-}"
PREFER_MIRROR="${PREFER_MIRROR:-}"
NIX_INSTALL_URL="${NIX_INSTALL_URL:-}"
NIX_CHANNEL="${NIX_CHANNEL:-}"
NIX_CHANNEL_URL="${NIX_CHANNEL_URL:-}"
NIX_SUBSTITUTERS="${NIX_SUBSTITUTERS:-}"
LOG_FILE="${LOG_FILE:-/var/log/nixos-infect.log}"
NO_COLOR="${NO_COLOR:-}"

# 安装流程开关（上游兼容）
NO_REBOOT="${NO_REBOOT:-}"
NO_SWAP="${NO_SWAP:-}"
NO_INFECT="${NO_INFECT:-}"

# ===========================================================================
# 颜色
# ===========================================================================
if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_MAGENTA=$'\033[35m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

# ===========================================================================
# 日志
# ===========================================================================
_log_write() {
  [ -n "$LOG_FILE" ] || return 0
  local level="$1"; shift
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "----")
  printf '%s [%s] %s\n' "$ts" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

log_info() {
  printf '%s[INFO]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
  _log_write INFO "$*"
}

log_warn() {
  printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
  _log_write WARN "$*"
}

log_error() {
  printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  _log_write ERROR "$*"
}

log_step() {
  printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"
  _log_write STEP "$*"
}

log_debug() {
  [ "$VERBOSE" = "1" ] || return 0
  printf '%s[DEBUG]%s %s\n' "$C_DIM" "$C_RESET" "$*"
  _log_write DEBUG "$*"
}

# ===========================================================================
# i18n
# ===========================================================================
declare -A MSG_EN=(
  [title_probe]="Nix Mirror Probe"
  [title_summary]="Probe Summary"
  [title_recommend]="Recommended Configuration"
  [title_interactive]="Interactive Configuration"
  [title_combination]="Combination Check"
  [title_config]="NixOS Configuration"
  [title_install]="Installation"

  [ok]="OK"
  [not_found]="NOT_FOUND"
  [na]="N/A"
  [official]="official"
  [default]="default"
  [default_order]="Default order"
  [hint_single]="single choice"
  [hint_multi]="multiple, ordered"

  [probe_no_curl]="Error: curl is required. Please install it first."
  [probe_running]="Probing mirrors, this may take a moment..."
  [probe_done]="Probe complete."
  [footnote_store_only]="* speed measured from mirror homepage (this mirror does not provide the nixpkgs-unstable tarball)."
  [footnote_speed]="Speed: 1MB range request on the Nix path (nixpkgs-unstable channel tarball), 3 rounds, median. Use --fast for 1 round."
  [footnote_untested_store]="OK = mirror reachable but speed not measurable (large Nix files blocked or unavailable)."
  [all_same]="All components come from the same mirror. No mixing risk."
  [mixed_note]="Install and Channels come from different mirrors. In nixos-infect these are configured independently, so mixing is fine."
  [prompt_install]="Choose install mirror"
  [prompt_channel]="Choose channels mirror"
  [prompt_store]="Choose store order"

  [provider_detected]="Detected provider: %s"
  [provider_choose]="Choose provider"
  [provider_auto]="auto (use detected)"
  [provider_auto_detail]="auto (detected: %s)"

  [config_existing]="Existing %s found"
  [config_existing_hint]="Choose how to proceed:"
  [config_choice_use]="Use it as-is and continue"
  [config_choice_review]="Review and edit in a shell"
  [config_choice_overwrite]="Overwrite with default configuration"
  [config_choice_prompt]="Choice"
  [config_summary_title]="Configuration summary"
  [config_summary_hostname]="Hostname"
  [config_summary_provider]="Provider"
  [config_summary_keys]="SSH authorized keys"
  [config_summary_channel]="NixOS channel"
  [config_summary_substituters]="Substituters"
  [config_enter_shell]="Entering shell. Edit the files, then type 'exit' to return."
  [config_file]="Config file"
  [config_related]="Related files"
  [config_proceed]="Proceed with this configuration?"
  [config_review_again]="Re-opening shell for further edits."
  [config_generating]="Generating default configuration"

  [install_start]="Starting NixOS installation"
  [install_nix]="Installing Nix"
  [install_channel]="Setting up channel"
  [install_parse_check]="Checking configuration.nix syntax"
  [install_parse_fail]="configuration.nix failed to parse"
  [install_parse_ok]="Syntax OK"
  [install_semantic_fail]="NixOS evaluation failed"
  [install_log_hint]="Full error written to"
  [install_write_conf]="Writing /etc/nix/nix.conf"
  [install_build]="Building system closure"
  [install_finalize]="Staging NixOS takeover"
  [install_done]="Installation complete"
  [install_reboot]="Rebooting into NixOS"
  [dry_run_done]="Dry run complete. No changes made."

  [yes]="yes"
  [no]="no"
  [cancelled]="Cancelled"
  [aborted]="Aborted"
)

declare -A MSG_ZH=(
  [title_probe]="Nix 镜像站探测"
  [title_summary]="探测结果汇总"
  [title_recommend]="推荐配置"
  [title_interactive]="交互式配置"
  [title_combination]="组合检查"
  [title_config]="NixOS 配置"
  [title_install]="安装"

  [ok]="OK"
  [not_found]="NOT_FOUND"
  [na]="N/A"
  [official]="官方"
  [default]="默认"
  [default_order]="默认顺序"
  [hint_single]="单选"
  [hint_multi]="多选，按优先级排序"

  [probe_no_curl]="错误：需要 curl，请先安装。"
  [probe_running]="正在探测镜像站，请稍候……"
  [probe_done]="探测完成。"
  [footnote_store_only]="* 该镜像站未提供 nixpkgs-unstable 文件，速度取自镜像站首页。"
  [footnote_speed]="速度：对 Nix 路径（nixpkgs-unstable channel 文件）发起 1MB range 请求，3 轮取中位数。--fast 可改为 1 轮。"
  [footnote_untested_store]="OK = 镜像站可达但无法测速（大文件被拒绝访问或不存在）。"
  [all_same]="所有组件来源一致，无混合风险。"
  [mixed_note]="Install 与 Channels 来自不同镜像站，nixos-infect 中这两者独立设置，混合使用正常。"
  [prompt_install]="选择 Install 镜像"
  [prompt_channel]="选择 Channels 镜像"
  [prompt_store]="选择 Store 顺序"

  [provider_detected]="检测到的云厂商：%s"
  [provider_choose]="选择云厂商"
  [provider_auto]="自动（使用检测值）"
  [provider_auto_detail]="自动（检测到：%s）"

  [config_existing]="发现已存在的 %s"
  [config_existing_hint]="请选择处理方式："
  [config_choice_use]="直接使用，继续安装"
  [config_choice_review]="进入 shell 审查和修改"
  [config_choice_overwrite]="用默认配置覆盖"
  [config_choice_prompt]="选择"
  [config_summary_title]="配置摘要"
  [config_summary_hostname]="主机名"
  [config_summary_provider]="云厂商"
  [config_summary_keys]="SSH 授权密钥"
  [config_summary_channel]="NixOS channel"
  [config_summary_substituters]="Substituters"
  [config_enter_shell]="进入 shell。编辑文件后输入 exit 返回。"
  [config_file]="配置文件"
  [config_related]="相关文件"
  [config_proceed]="使用此配置继续？"
  [config_review_again]="重新打开 shell 继续修改。"
  [config_generating]="正在生成默认配置"

  [install_start]="开始安装 NixOS"
  [install_nix]="安装 Nix"
  [install_channel]="配置 channel"
  [install_parse_check]="检查 configuration.nix 语法"
  [install_parse_fail]="configuration.nix 语法错误"
  [install_parse_ok]="语法正确"
  [install_semantic_fail]="NixOS 求值失败"
  [install_log_hint]="详细日志已写入"
  [install_write_conf]="写入 /etc/nix/nix.conf"
  [install_build]="构建系统闭包"
  [install_finalize]="准备 NixOS 接管"
  [install_done]="安装完成"
  [install_reboot]="即将重启进入 NixOS"
  [dry_run_done]="Dry run 完成，未做任何改动。"

  [yes]="是"
  [no]="否"
  [cancelled]="已取消"
  [aborted]="已中止"
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
  # shellcheck disable=SC2059
  printf "$template" "$@"
}

# ===========================================================================
# 显示宽度：ASCII 1 列，CJK 2 列
# ===========================================================================
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
  local text_width
  text_width=$(display_width "$text")
  local pad=$(( (width - text_width) / 2 ))
  [ "$pad" -lt 0 ] && pad=0
  local right_pad=$(( width - pad - text_width ))
  [ "$right_pad" -lt 0 ] && right_pad=0
  local line
  line=$(printf '─%.0s' $(seq 1 "$width"))
  printf "${C_DIM}%s${C_RESET}\n" "$line"
  printf "%*s${C_BOLD}${C_CYAN}%s${C_RESET}%*s\n" "$pad" "" "$text" "$right_pad" ""
  printf "${C_DIM}%s${C_RESET}\n" "$line"
}

# 键值对打印：按显示宽度对齐
# 用法: print_kv "Label" "value" [target_width]
print_kv() {
  local key="$1"
  local value="$2"
  local target_width="${3:-22}"
  local kw
  kw=$(display_width "$key")
  local pad=$((target_width - kw))
  [ "$pad" -lt 0 ] && pad=0
  local spaces
  spaces=$(printf '%*s' "$pad" '')
  printf "  %s%s: ${C_CYAN}%s${C_RESET}\n" "$key" "$spaces" "$value"
}

# ===========================================================================
# 通用输入
# ===========================================================================
# confirm "prompt" [y|n]  → 返回 0 表示 yes
confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local hint
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s %s ' "$prompt" "$hint"
  local ans
  read -r ans || ans=""
  ans=$(printf '%s' "$ans" | tr -d ' ' | tr 'A-Z' 'a-z')
  [ -z "$ans" ] && ans="$default"
  [ "$ans" = "y" ] || [ "$ans" = "yes" ]
}

# 进入 shell 让用户编辑（子 shell，不污染父环境）
enter_shell() {
  log_info "$(msg config_enter_shell)"
  (cd "$CONFIG_DIR" && bash) || true
}
