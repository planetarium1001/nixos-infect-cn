# ===========================================================================
# module: 00-base.sh
# ===========================================================================
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

# ===========================================================================
# module: 10-probe.sh
# ===========================================================================
# ===== module: 10-probe.sh =====
# 镜像探测：HTTP 探测 + 测速 + 推荐 + 交互选择
# 依赖: 00-base
# 暴露: probe_run / probe_report / probe_interactive / resolve_channel
# 全局: CHANNEL / PREFER_MIRROR / MODE / VERBOSE / FAST_MODE
#       NIX_INSTALL_URL / NIX_CHANNEL / NIX_CHANNEL_URL / NIX_SUBSTITUTERS

MIRRORS=(
  "TUNA|https://mirrors.tuna.tsinghua.edu.cn|/nix/latest/install"
  "NJU|https://mirror.nju.edu.cn|/nix/latest/install"
  "USTC|https://mirrors.ustc.edu.cn|"
  "SJTUG|https://mirror.sjtu.edu.cn|"
  "BFSU|https://mirrors.bfsu.edu.cn|/nix/latest/install"
)

INSTALL_VARIANTS=(
  "/nix/latest/install"
  "/nix/install"
  "/nix/nix-installer/latest/install"
)

CHANNEL_PATH="/nix-channels"
STORE_PATH="/nix-channels/store"

# 通用测速目标：TUNA/NJU/BFSU/USTC 均有此文件（约 38MB）；SJTUG 无
GENERIC_SPEED_PATH="/nix-channels/nixpkgs-unstable/nixexprs.tar.xz"

SPEED_ROUNDS=3
CONNECT_TIMEOUT=5
MAX_TIME=30
RANGE_BYTES=1048576     # 1MB
MIN_VALID_BYTES=262144  # 256KB，低于此值的测速结果视为无效

declare -A R_INSTALL_URL
declare -A R_CHANNEL_URL
declare -A R_STORE_URL
declare -A R_CHANNEL_OK
declare -A R_STORE_OK
declare -A R_MIRROR_SPEED       # 每个镜像的整体速度（整数 B/s，0 表示未测到）
declare -A R_MIRROR_STORE_ONLY  # 1 = 该镜像使用了非通用路径（首页兜底）测速

# ===========================================================================
# 基础探测
# ===========================================================================
probe_http() {
  local url="$1"
  local code
  code=$(curl -sI -o /dev/null -w "%{http_code}" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -L "$url" 2>/dev/null || echo "000")
  # 5xx / 000 时重试一次
  case "$code" in
    000|500|502|503|504)
      sleep 1
      code=$(curl -sI -o /dev/null -w "%{http_code}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        -L "$url" 2>/dev/null || echo "000")
      ;;
  esac
  echo "$code"
}

# 返回 "time_total speed_download"，或 "0 0" 表示无效
speed_test_range() {
  local url="$1"
  local out
  out=$(curl -sL -r "0-$((RANGE_BYTES - 1))" -o /dev/null \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -w "%{time_total} %{size_download} %{speed_download}" \
    "$url" 2>/dev/null || echo "0 0 0")
  local t sz sp
  t=$(printf '%s' "$out" | awk '{print $1}')
  sz=$(printf '%s' "$out" | awk '{print $2}')
  sp=$(printf '%s' "$out" | awk '{print $3}')
  sz=${sz%%.*}
  if [ -z "$sz" ] || [ "$sz" -lt "$MIN_VALID_BYTES" ] 2>/dev/null; then
    echo "0 0"
    return
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
  if [ "$n" -eq 0 ]; then
    echo "0"
    return
  fi
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
  if [ -z "$bps" ] || [ "$bps" = "0" ]; then
    echo "$C_DIM"
  elif [ "$bps" -ge 1048576 ] 2>/dev/null; then
    echo "$C_GREEN"
  elif [ "$bps" -ge 307200 ] 2>/dev/null; then
    echo "$C_YELLOW"
  else
    echo "$C_RED"
  fi
}

fmt_speed() {
  local bps="$1"
  local c
  c=$(speed_color "$bps")
  echo "${c}$(fmt_speed_raw "$bps")${C_RESET}"
}

is_ok() {
  case "$1" in
    200|301|302|303|307|308) return 0 ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# channel 解析
# ===========================================================================
resolve_channel() {
  [ -n "$NIX_CHANNEL" ] && { echo "$NIX_CHANNEL"; return; }

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
    echo "$latest"
  else
    echo "nixos-25.11"
  fi
}

# ===========================================================================
# 全量探测
# ===========================================================================
probe_all() {
  local entry name base known_install
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name base known_install <<< "$entry"

    # --- Install ---
    local found_install=""
    local url code variant
    if [ -n "$known_install" ]; then
      url="${base}${known_install}"
      code=$(probe_http "$url")
      is_ok "$code" && found_install="$url"
    fi
    if [ -z "$found_install" ]; then
      for variant in "${INSTALL_VARIANTS[@]}"; do
        url="${base}${variant}"
        code=$(probe_http "$url")
        if is_ok "$code"; then
          found_install="$url"
          break
        fi
      done
    fi
    R_INSTALL_URL[$name]="${found_install}"

    # --- Channels ---
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

    # --- Store ---
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

    # --- 整体测速 ---
    # 优先级：
    #   1. nixpkgs-unstable/nixexprs.tar.xz（通用大文件，走 Nix 路径）
    #   2. 当前 channel 的 nixexprs.tar.xz（保留，兜底）
    #   3. 镜像站首页（最后兜底）
    # R_MIRROR_STORE_ONLY 只在"通过首页测到了速度"时才设置，
    # 用于脚注说明"该镜像站的测速值来自首页"。
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
        R_MIRROR_STORE_ONLY[$name]=1
      fi
    fi
    R_MIRROR_SPEED[$name]="$mirror_speed"
  done
}

# ===========================================================================
# 推荐逻辑
# ===========================================================================
pick_best() {
  local kind="$1"
  local best_name=""
  local best_speed=-1
  local entry name
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    local available=0
    case "$kind" in
      install) [ -n "${R_INSTALL_URL[$name]}" ] && available=1 ;;
      channel) [ "${R_CHANNEL_OK[$name]}" = "1" ] && available=1 ;;
    esac
    [ "$available" = "1" ] || continue
    local s="${R_MIRROR_SPEED[$name]:-0}"
    if [ "$s" -gt "$best_speed" ] 2>/dev/null; then
      best_speed="$s"
      best_name="$name"
    fi
  done
  echo "$best_name"
}

pick_with_preference() {
  local kind="$1"
  if [ -n "$PREFER_MIRROR" ]; then
    local preferred_ok=0
    case "$kind" in
      install) [ -n "${R_INSTALL_URL[$PREFER_MIRROR]}" ] && preferred_ok=1 ;;
      channel) [ "${R_CHANNEL_OK[$PREFER_MIRROR]}" = "1" ] && preferred_ok=1 ;;
    esac
    if [ "$preferred_ok" = "1" ]; then
      echo "$PREFER_MIRROR"
      return
    fi
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

# ===========================================================================
# 探测入口
# ===========================================================================
probe_run() {
  if ! command -v curl >/dev/null 2>&1; then
    log_error "$(msg probe_no_curl)"
    exit 1
  fi

  if [ -z "$NIX_CHANNEL" ]; then
    NIX_CHANNEL=$(resolve_channel)
    log_debug "resolved channel: $NIX_CHANNEL"
  fi

  log_step "$(msg probe_running)"
  probe_all

  local best_install best_channel best_store
  best_install=$(pick_with_preference install)
  best_channel=$(pick_with_preference channel)
  best_store=$(pick_store_list)

  if [ -n "$best_install" ] && [ "$best_install" != "__official__" ]; then
    NIX_INSTALL_URL="${R_INSTALL_URL[$best_install]}"
  else
    NIX_INSTALL_URL="${NIX_INSTALL_URL:-https://nixos.org/nix/install}"
  fi

  if [ -n "$best_channel" ] && [ "$best_channel" != "__official__" ]; then
    NIX_CHANNEL_URL="${R_CHANNEL_URL[$best_channel]}"
  else
    NIX_CHANNEL_URL="${NIX_CHANNEL_URL:-https://nixos.org/channels/$NIX_CHANNEL}"
  fi

  local subs=""
  local name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    [ -n "${R_STORE_URL[$name]}" ] || continue
    subs="$subs ${R_STORE_URL[$name]}"
  done <<< "$best_store"
  subs="${subs# }"
  if [ -n "$subs" ]; then
    NIX_SUBSTITUTERS="$subs https://cache.nixos.org/"
  else
    NIX_SUBSTITUTERS="https://cache.nixos.org/"
  fi
}

# ===========================================================================
# 探测摘要
# ===========================================================================
probe_report() {
  print_title "$(msg title_summary)"

  printf "${C_BOLD}%-8s %-14s %-14s %-14s${C_RESET}\n" \
    "Mirror" "Install" "Channels" "Store"
  printf "${C_DIM}%-8s %-14s %-14s %-14s${C_RESET}\n" \
    "------" "-------" "--------" "-----"

  local entry name
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"

    local speed="${R_MIRROR_SPEED[$name]:-0}"
    local c_sp
    if [ "$speed" = "0" ] || [ -z "$speed" ]; then
      c_sp="$C_DIM"
    else
      c_sp=$(speed_color "$speed")
    fi
    local speed_str
    speed_str=$(fmt_speed_raw "$speed")

    local c_inst txt_inst c_ch txt_ch c_st txt_st
    # Install：OK 时一定有速度（能拿到 install 脚本意味着能测速）
    if [ -n "${R_INSTALL_URL[$name]}" ]; then
      c_inst="$c_sp"; txt_inst="$speed_str"
    else
      c_inst="$C_RED"; txt_inst="$(msg not_found)"
    fi

    # Channels：同上
    if [ "${R_CHANNEL_OK[$name]}" = "1" ]; then
      c_ch="$c_sp"; txt_ch="$speed_str"
    else
      c_ch="$C_RED"; txt_ch="$(msg not_found)"
    fi

    # Store：可用但无速度时显示 OK（黄色），不显示 —（避免跟 NOT_FOUND 混淆）
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

  # 脚注：store-only 镜像（用了首页兜底测速）
  local has_store_only=0
  local has_untested_store=0
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    [ "${R_MIRROR_STORE_ONLY[$name]}" = "1" ] && has_store_only=1
    if [ "${R_STORE_OK[$name]}" = "1" ] && [ "${R_MIRROR_SPEED[$name]:-0}" = "0" ]; then
      has_untested_store=1
    fi
  done
  [ "$has_store_only" = "1" ] && echo "${C_DIM}$(msg footnote_store_only)${C_RESET}"
  [ "$has_untested_store" = "1" ] && echo "${C_DIM}$(msg footnote_untested_store)${C_RESET}"
  echo "${C_DIM}$(msg footnote_speed)${C_RESET}"
  echo ""
}

# ===========================================================================
# 交互选择
# ===========================================================================
probe_interactive() {
  echo ""
  print_title "$(msg title_interactive)"
  echo ""

  local entry name idx choice i
  local best_install best_channel best_store
  best_install=$(pick_with_preference install)
  best_channel=$(pick_with_preference channel)
  best_store=$(pick_store_list)

  # ---------- Install ----------
  echo "${C_MAGENTA}[ $(msg prompt_install) ]${C_RESET} ${C_DIM}($(msg hint_single))${C_RESET}"
  local -a install_names=()
  idx=0
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ -n "${R_INSTALL_URL[$name]}" ]; then
      idx=$((idx + 1))
      install_names+=("$name")
      printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} %s\n" \
        "$idx" "$name" "$(fmt_speed "${R_MIRROR_SPEED[$name]:-0}")"
    fi
  done
  idx=$((idx + 1))
  install_names+=("__official__")
  printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} ${C_DIM}%s${C_RESET}\n" \
    "$idx" "$(msg official)" "https://nixos.org/nix/install"

  local default_idx=1
  for i in "${!install_names[@]}"; do
    if [ "${install_names[$i]}" = "$best_install" ]; then
      default_idx=$((i + 1)); break
    fi
  done

  printf "%s [1-%d] ${C_YELLOW}(%s: %d=%s)${C_RESET}: " \
    "$(msg prompt_install)" "$idx" "$(msg default)" "$default_idx" "${install_names[$((default_idx - 1))]}"
  read -r choice || choice=""
  [ -z "$choice" ] && choice="$default_idx"
  if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$idx" ]; then
    best_install="${install_names[$((choice - 1))]}"
  fi
  echo ""

  # ---------- Channels ----------
  echo "${C_MAGENTA}[ $(msg prompt_channel) ]${C_RESET} ${C_DIM}($(msg hint_single))${C_RESET}"
  local -a channel_names=()
  idx=0
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ "${R_CHANNEL_OK[$name]}" = "1" ]; then
      idx=$((idx + 1))
      channel_names+=("$name")
      printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} %s\n" \
        "$idx" "$name" "$(fmt_speed "${R_MIRROR_SPEED[$name]:-0}")"
    fi
  done
  idx=$((idx + 1))
  channel_names+=("__official__")
  printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} ${C_DIM}%s${C_RESET}\n" \
    "$idx" "$(msg official)" "https://nixos.org/channels/${NIX_CHANNEL}"

  default_idx=1
  for i in "${!channel_names[@]}"; do
    if [ "${channel_names[$i]}" = "$best_channel" ]; then
      default_idx=$((i + 1)); break
    fi
  done

  printf "%s [1-%d] ${C_YELLOW}(%s: %d=%s)${C_RESET}: " \
    "$(msg prompt_channel)" "$idx" "$(msg default)" "$default_idx" "${channel_names[$((default_idx - 1))]}"
  read -r choice || choice=""
  [ -z "$choice" ] && choice="$default_idx"
  if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$idx" ]; then
    best_channel="${channel_names[$((choice - 1))]}"
  fi
  echo ""

  # ---------- Store ----------
  echo "${C_MAGENTA}[ $(msg prompt_store) ]${C_RESET} ${C_DIM}($(msg hint_multi))${C_RESET}"
  local -a store_names=()
  idx=0
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ "${R_STORE_OK[$name]}" = "1" ]; then
      idx=$((idx + 1))
      store_names+=("$name")
      printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} %s\n" \
        "$idx" "$name" "$(fmt_speed "${R_MIRROR_SPEED[$name]:-0}")"
    fi
  done

  local default_order="" default_names=""
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    for i in "${!store_names[@]}"; do
      if [ "${store_names[$i]}" = "$name" ]; then
        if [ -z "$default_order" ]; then
          default_order="$((i + 1))"
          default_names="$name"
        else
          default_order="${default_order},$((i + 1))"
          default_names="${default_names},$name"
        fi
      fi
    done
  done <<< "$best_store"

  echo "  ${C_YELLOW}$(msg default_order): ${default_order} = ${default_names}${C_RESET}"
  printf "%s ${C_YELLOW}(%s: %s)${C_RESET}: " \
    "$(msg prompt_store)" "$(msg default)" "$default_order"
  local store_order
  read -r store_order || store_order=""
  [ -z "$store_order" ] && store_order="$default_order"

  local new_store_list=""
  local token
  while IFS= read -r token; do
    token=$(printf '%s' "$token" | tr -d ' ')
    [ -z "$token" ] && continue
    if [ "$token" -ge 1 ] 2>/dev/null && [ "$token" -le "$idx" ]; then
      new_store_list="${new_store_list}${store_names[$((token - 1))]}"$'\n'
    fi
  done <<< "$(printf '%s' "$store_order" | tr ',' '\n')"
  best_store="$new_store_list"
  echo ""

  # ---------- 应用选择 ----------
  if [ -n "$best_install" ] && [ "$best_install" != "__official__" ]; then
    NIX_INSTALL_URL="${R_INSTALL_URL[$best_install]}"
  else
    NIX_INSTALL_URL="https://nixos.org/nix/install"
  fi

  if [ -n "$best_channel" ] && [ "$best_channel" != "__official__" ]; then
    NIX_CHANNEL_URL="${R_CHANNEL_URL[$best_channel]}"
  else
    NIX_CHANNEL_URL="https://nixos.org/channels/$NIX_CHANNEL"
  fi

  local subs=""
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    [ -n "${R_STORE_URL[$name]}" ] || continue
    subs="$subs ${R_STORE_URL[$name]}"
  done <<< "$best_store"
  subs="${subs# }"
  if [ -n "$subs" ]; then
    NIX_SUBSTITUTERS="$subs https://cache.nixos.org/"
  else
    NIX_SUBSTITUTERS="https://cache.nixos.org/"
  fi
}

# ===========================================================================
# module: 20-config.sh
# ===========================================================================
# ===== module: 20-config.sh =====
# provider 检测 + 生成 configuration.nix/hardware-configuration.nix/networking.nix
# + 编辑循环
# 依赖: 00-base
# 暴露: sys_detect_provider / sys_provider_interactive / config_flow
#       make_conf / make_hardware_conf / make_networking_conf
# 全局: PROVIDER / MODE / LANG_OPT / NIX_SUBSTITUTERS / NIX_CHANNEL
#       esp / grubdev / rootfsdev / rootfstype / swapcfg / zramswap / doNetConf
#       CONFIG_DIR（默认 /etc/nixos，dry-run 时由 30-install 覆盖为 /tmp/...）

CONFIG_DIR="${CONFIG_DIR:-/etc/nixos}"

# ===========================================================================
# Provider 检测
# ===========================================================================
sys_detect_provider() {
  [ -n "$PROVIDER" ] && return

  if [ -e /etc/hetzner-build ]; then
    PROVIDER="hetznercloud"
    return
  fi

  local vendor=""
  [ -r /sys/class/dmi/id/sys_vendor ] && vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
  case "$vendor" in
    *Tencent*|*tencent*) PROVIDER="tencent-cloud" ;;
    *Alibaba*|*alibaba*) PROVIDER="aliyun" ;;
    *Amazon*|*amazon*)   PROVIDER="aws" ;;
    *)                   PROVIDER="unknown" ;;
  esac
}

sys_provider_interactive() {
  log_info "$(msg_fmt provider_detected "$PROVIDER")"
  echo "${C_MAGENTA}[ $(msg provider_choose) ]${C_RESET}"

  # 国内云厂商 + auto + unknown
  local -a choices=(auto tencent-cloud aliyun huawei-cloud ucloud unknown)
  # 如果检测到的 provider 不在列表里（例如 hetznercloud），追加进来
  local found=0 c
  for c in "${choices[@]}"; do
    [ "$c" = "$PROVIDER" ] && found=1
  done
  if [ "$found" = "0" ] && [ "$PROVIDER" != "auto" ] && [ "$PROVIDER" != "unknown" ]; then
    choices+=("$PROVIDER")
  fi

  local i=0
  for c in "${choices[@]}"; do
    i=$((i + 1))
    local label="$c"
    [ "$c" = "auto" ] && label="$(msg_fmt provider_auto_detail "$PROVIDER")"
    printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%s${C_RESET}\n" "$i" "$label"
  done

  local default_idx=1
  for i in "${!choices[@]}"; do
    if [ "${choices[$i]}" = "$PROVIDER" ]; then
      default_idx=$((i + 1)); break
    fi
  done

  printf "%s [1-${#choices[@]}] ${C_YELLOW}(%s: %d)${C_RESET}: " \
    "$(msg provider_choose)" "$(msg default)" "$default_idx"
  local choice
  read -r choice || choice=""
  [ -z "$choice" ] && choice="$default_idx"
  if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#choices[@]}" ]; then
    local selected="${choices[$((choice - 1))]}"
    [ "$selected" != "auto" ] && PROVIDER="$selected"
  fi
  echo ""
  log_info "$(msg_fmt provider_detected "$PROVIDER")"
}

# ===========================================================================
# 系统信息（安装前需要）
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

# ===========================================================================
# 生成 configuration.nix
# ===========================================================================
# 生成 Nix 列表格式的 substituters 块
_subs_nix_block() {
  local IFS=' '
  local url
  for url in $NIX_SUBSTITUTERS; do
    printf '    "%s"\n' "$url"
  done
}

generate_config_nix() {
  local keys=""
  local IFS=$'\n'
  local trypath
  for trypath in /root/.ssh/authorized_keys /home/${SUDO_USER:-root}/.ssh/authorized_keys $HOME/.ssh/authorized_keys; do
    if [ -r "$trypath" ]; then
      keys=$(sed -E 's/^[^#].*[[:space:]]((sk-ssh|sk-ecdsa|ssh|ecdsa)-[^[:space:]]+)[[:space:]]+([^[:space:]]+)([[:space:]]*.*)$/\1 \3\4/' "$trypath")
      [ -n "$keys" ] && break
    fi
  done

  local keys_nix=""
  if [ -n "$keys" ]; then
    local line trimmed
    while read -r line; do
      line=$(printf '%s' "$line" | sed 's/\r//g')
      trimmed=$(printf '%s' "$line" | xargs)
      [ -z "$trimmed" ] && continue
      keys_nix="${keys_nix}
    \"${trimmed}\""
    done <<< "$keys"
  fi

  local network_import=""
  [ -n "$doNetConf" ] && network_import="./networking.nix # generated at runtime by nixos-infect"

  local hostname_s domain_s
  hostname_s=$(hostname -s 2>/dev/null || echo "nixos")
  domain_s=$(hostname -d 2>/dev/null || echo "")

  local subs_block
  subs_block=$(_subs_nix_block)

  local zram_val="true"
  [ "$zramswap" = "false" ] && zram_val="false"

  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/configuration.nix" << EOF
{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    $network_import
  ];

  # 国内镜像 substituters（由 nixos-infect-cn 生成）
  nix.settings.substituters = [
$subs_block
  ];

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = $zram_val;
  networking.hostName = "$hostname_s";
  networking.domain = "$domain_s";
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [ $keys_nix
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
EOF
}

generate_hardware_config() {
  local bootcfg
  if isEFI; then
    bootcfg=$(cat << EOF
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  fileSystems."/boot" = { device = "$esp"; fsType = "vfat"; };
EOF
)
  else
    bootcfg=$(cat << EOF
  boot.loader.grub.device = "$grubdev";
EOF
)
  fi

  local availableKernelModules=('"ata_piix"' '"uhci_hcd"' '"xen_blkfront"')
  if isX86_64; then
    availableKernelModules+=('"vmw_pvscsi"')
  fi

  cat > "$CONFIG_DIR/hardware-configuration.nix" << EOF
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
$bootcfg
  boot.initrd.availableKernelModules = [ ${availableKernelModules[@]} ];
  boot.initrd.kernelModules = [ "nvme" ];
  fileSystems."/" = { device = "$rootfsdev"; fsType = "$rootfstype"; };
  $swapcfg
}
EOF
}

generate_networking_conf() {
  local IFS=$'\n'
  local eth0_name eth0_ip4s eth0_ip6s gateway gateway6 ether0
  eth0_name=$(ip address show | grep '^2:' | awk -F': ' '{print $2}')
  eth0_ip4s=$(ip address show dev "$eth0_name" | grep 'inet ' | sed -r 's|.*inet ([0-9.]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|')
  eth0_ip6s=$(ip address show dev "$eth0_name" | grep 'inet6 ' | sed -r 's|.*inet6 ([0-9a-f:]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|' || true)
  gateway=$(ip route show dev "$eth0_name" | grep default | sed -r 's|default via ([0-9.]+).*|\1|')
  gateway6=$(ip -6 route show dev "$eth0_name" | grep default | sed -r 's|default via ([0-9a-f:]+).*|\1|' || true)
  ether0=$(ip address show dev "$eth0_name" | grep link/ether | sed -r 's|.*link/ether ([0-9a-f:]+) .*|\1|')

  local nameservers
  nameservers=$(grep ^nameserver /etc/resolv.conf | sed -r \
    -e 's/^nameserver[[:space:]]+([0-9.a-fA-F:]+).*/"\1"/' \
    -e 's/127[0-9.]+/8.8.8.8/' \
    -e 's/::1/8.8.8.8/' | tr '\n' ' ')

  local predictable_inames="usePredictableInterfaceNames = lib.mkForce true;"
  case "$eth0_name" in eth*) predictable_inames="usePredictableInterfaceNames = lib.mkForce false;" ;; esac

  cat > "$CONFIG_DIR/networking.nix" << EOF
{ lib, ... }: {
  networking = {
    nameservers = [ $nameservers ];
    defaultGateway = "$gateway";
    defaultGateway6 = {
      address = "$gateway6";
      interface = "$eth0_name";
    };
    dhcpcd.enable = false;
    $predictable_inames
    interfaces = {
      $eth0_name = {
        ipv4.addresses = [$eth0_ip4s];
        ipv6.addresses = [$eth0_ip6s];
        ipv4.routes = [ { address = "$gateway"; prefixLength = 32; } ];
        ipv6.routes = [ { address = "$gateway6"; prefixLength = 128; } ];
      };
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="$ether0", NAME="$eth0_name"
  '';
}
EOF
}

make_conf() {
  log_step "$(msg config_generating)"
  generate_config_nix
  generate_hardware_config
  [ -n "$doNetConf" ] && generate_networking_conf
}

# ===========================================================================
# 配置摘要
# ===========================================================================
config_summary() {
  local key_count=0
  local kf count
  for kf in /root/.ssh/authorized_keys /home/${SUDO_USER:-root}/.ssh/authorized_keys $HOME/.ssh/authorized_keys; do
    if [ -r "$kf" ]; then
      count=$(grep -v '^#' "$kf" 2>/dev/null | grep -c . || true)
      count=$(printf '%s' "$count" | tr -d ' \n')
      count=${count:-0}
      if [ "$count" -gt 0 ] 2>/dev/null; then
        key_count="$count"
        break
      fi
    fi
  done

  echo ""
  print_title "$(msg config_summary_title)"
  print_kv "$(msg config_summary_hostname)"    "$(hostname -s 2>/dev/null || echo unknown)"
  print_kv "$(msg config_summary_provider)"    "$PROVIDER"
  print_kv "$(msg config_summary_keys)"        "$key_count"
  print_kv "$(msg config_summary_channel)"     "$NIX_CHANNEL"
  print_kv "$(msg config_summary_substituters)" "$NIX_SUBSTITUTERS"
  echo ""
}

# ===========================================================================
# 编辑循环
# ===========================================================================
edit_loop() {
  while :; do
    config_summary
    echo "  ${C_DIM}$(msg config_file): $CONFIG_DIR/configuration.nix${C_RESET}"
    echo "  ${C_DIM}$(msg config_related): $CONFIG_DIR/hardware-configuration.nix${C_RESET}"
    echo ""

    if [ "$ASSUME_YES" != "1" ]; then
      if confirm "$(msg config_proceed)" y; then
        return 0
      fi
      log_info "$(msg config_review_again)"
    else
      return 0
    fi
    enter_shell
  done
}

# ===========================================================================
# 主流程：重跑检测 + 生成 + 编辑
# ===========================================================================
config_flow() {
  local existing=0
  [ -e "$CONFIG_DIR/configuration.nix" ] && existing=1

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
          if [ -f "$CONFIG_DIR/configuration.nix" ] && [ "$MODE" = "interactive" ]; then
            edit_loop
          fi
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

  # 全新生成
  make_conf
  if [ "$MODE" = "interactive" ]; then
    edit_loop
  fi
}

# ===========================================================================
# module: 30-install.sh
# ===========================================================================
#!/usr/bin/env bash
# ===== module: 30-install.sh =====
# Nix 安装 + channel 设置 + 语法/语义检查循环 + 系统接管 + main 入口
# 依赖: 全部
# 暴露: main

# ===========================================================================
# 环境准备
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
  req cut || req df    || { log_error "Missing coreutils";        exit 1; }
  req tar              || { log_error "Missing tar";              exit 1; }

  if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    chmod 600 /etc/ssh/ssh_host_*_key
  fi
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

makeSwap() {
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

# ===========================================================================
# /etc/nix/nix.conf
# ===========================================================================
write_nix_conf() {
  log_step "$(msg install_write_conf)"
  mkdir -p /etc/nix
  # 保留已有内容中的 trusted-public-keys，追加/覆盖 substituters
  local keys_line='trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY='
  if [ -f /etc/nix/nix.conf ]; then
    # 移除旧的 substituters 和 trusted-public-keys 行
    sed -i.bak -E '/^(substituters|trusted-public-keys)[[:space:]]*=/d' /etc/nix/nix.conf 2>/dev/null || true
  fi
  {
    echo "substituters = $NIX_SUBSTITUTERS"
    echo "$keys_line"
    [ -f /etc/nix/nix.conf ] && cat /etc/nix/nix.conf || true
  } > /etc/nix/nix.conf.new
  mv /etc/nix/nix.conf.new /etc/nix/nix.conf
  log_debug "nix.conf written, substituters=$NIX_SUBSTITUTERS"
}

# ===========================================================================
# 安装 Nix
# ===========================================================================
install_nix() {
  log_step "$(msg install_nix)"

  groupadd nixbld -g 30000 2>/dev/null || true
  local i
  for i in $(seq 1 10); do
    useradd -c "Nix build user $i" -d /var/empty -g nixbld -G nixbld -M -N -r -s "$(command -v nologin || echo /usr/sbin/nologin)" "nixbld$i" 2>/dev/null || true
  done

  log_debug "downloading installer from $NIX_INSTALL_URL"
  if ! curl -fsSL "$NIX_INSTALL_URL" | sh -s -- --no-channel-add; then
    log_error "Nix installation failed"
    exit 1
  fi

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
  if ! nix-channel --update; then
    log_error "nix-channel --update failed"
    exit 1
  fi
}

# ===========================================================================
# 检查循环
# ===========================================================================
parse_check_loop() {
  log_step "$(msg install_parse_check)"
  while :; do
    local err
    if err=$(nix-instantiate --parse /etc/nixos/configuration.nix 2>&1 >/dev/null); then
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
    enter_shell
  done
}

semantic_check_loop() {
  log_step "$(msg install_build)"
  local nixpkgs_path nixos_config_path
  nixpkgs_path="$(realpath "$HOME/.nix-defexpr/channels/nixos")"
  nixos_config_path="$CONFIG_DIR/configuration.nix"

  while :; do
    local err
    if err=$(nix-env --set \
        -I "nixpkgs=$nixpkgs_path" \
        -I "nixos-config=$nixos_config_path" \
        -f '<nixpkgs/nixos>' \
        -p /nix/var/nix/profiles/system \
        -A system 2>&1 >/dev/null); then
      return 0
    fi
    log_error "$(msg install_semantic_fail)"
    {
      echo "===== $(date) nix-env error ====="
      echo "$err"
    } >> "$LOG_FILE" 2>/dev/null || true
    printf '%s %s\n' "$(msg install_log_hint)" "$LOG_FILE" >&2
    printf '%s\n' "$err" | head -30 >&2 || true
    enter_shell
  done
}

# ===========================================================================
# 系统接管
# ===========================================================================
finalize_nixos() {
  log_step "$(msg install_finalize)"

  rm -fv /nix/var/nix/profiles/default* >/dev/null 2>&1 || true
  /nix/var/nix/profiles/system/sw/bin/nix-collect-garbage >/dev/null 2>&1 || true

  if [ -L /etc/resolv.conf ]; then
    mv -v /etc/resolv.conf /etc/resolv.conf.lnk >/dev/null 2>&1 || true
    cat /etc/resolv.conf.lnk > /etc/resolv.conf 2>/dev/null || true
  fi

  touch /etc/NIXOS
  echo etc/nixos                  >> /etc/NIXOS_LUSTRATE
  echo etc/resolv.conf            >> /etc/NIXOS_LUSTRATE
  echo root/.nix-defexpr/channels >> /etc/NIXOS_LUSTRATE
  (cd / && ls etc/ssh/ssh_host_*_key* 2>/dev/null || true) >> /etc/NIXOS_LUSTRATE

  if isEFI; then
    rm -rf /boot.bak
    umount "$esp" 2>/dev/null || true
    mv -v /boot /boot.bak 2>/dev/null || { cp -a /boot /boot.bak; rm -rf /boot/*; umount /boot 2>/dev/null || true; }
    mkdir -p /boot
    mount "$esp" /boot
    find /boot -depth ! -path /boot -exec rm -rf {} + 2>/dev/null || true
  fi

  /nix/var/nix/profiles/system/bin/switch-to-configuration boot
}

# ===========================================================================
# 参数解析
# ===========================================================================
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --lang=zh|--lang=zh_CN|--lang=zh_TW) LANG_OPT="zh" ;;
      --lang=en) LANG_OPT="en" ;;
      --verbose) VERBOSE=1 ;;
      --interactive) MODE="interactive" ;;
      --auto) MODE="auto" ;;
      --yes) ASSUME_YES=1 ;;
      --no-probe) NIX_INSTALL_URL="${NIX_INSTALL_URL:-__skip__}" ;;
      --fast) FAST_MODE=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-reboot) NO_REBOOT=1 ;;
      --no-swap) NO_SWAP=1 ;;
      --no-infect) NO_INFECT=1 ;;
      --prefer=*) PREFER_MIRROR="${arg#*=}" ;;
      --channel=*) CHANNEL="${arg#*=}"; NIX_CHANNEL="${arg#*=}" ;;
      --no-color) NO_COLOR=1 ;;
      --help|-h) show_help; exit 0 ;;
      --) shift; break ;;
      -*) log_error "Unknown option: $arg"; show_help; exit 1 ;;
    esac
  done
}

show_help() {
  cat <<'USAGE'
Usage: nixos-infect.sh [OPTIONS]

Options:
  --lang=en|zh             Output language (default: en)
  --interactive            Interactive mode: choose provider and edit config
  --auto                   Fully automatic (default)
  --yes                    Skip final confirmation
  --no-probe               Skip mirror probe (use env vars or built-in defaults)
  --fast                   Fast probe: 1 speed round per mirror (less traffic)
  --dry-run                Probe + generate config, do not install
  --no-reboot              Do not reboot after install
  --no-swap                Do not create temporary swap
  --no-infect              Prepare only, skip actual install
  --prefer=NAME            Prefer mirror (TUNA, NJU, USTC, SJTUG, BFSU)
  --channel=CHANNEL        NixOS channel (default: auto-detect)
  --verbose                Show debug output
  --no-color               Disable colored output
  --help                   Show this help

Environment:
  NIX_INSTALL_URL          Override installer URL
  NIX_CHANNEL              Override channel name
  NIX_CHANNEL_URL          Override channel URL
  NIX_SUBSTITUTERS         Space-separated substituter URLs
  PROVIDER                 Override provider detection
  NO_REBOOT, NO_SWAP, NO_INFECT
USAGE
}

# ===========================================================================
# 入口
# ===========================================================================
main() {
  parse_args "$@"
  # Dry-run 时输出到 /tmp，不写 /etc/nixos
  if [ "${DRY_RUN:-0}" = "1" ]; then
    export CONFIG_DIR="/tmp/nixos-infect-dryrun"
    rm -rf "$CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"
    log_info "dry-run: output directory $CONFIG_DIR"
  fi

  log_step "$(msg title_install) [nixos-infect-cn v$NIXOS_INFECT_CN_VERSION]"

  # 1) provider 检测 + interactive 选择
  sys_detect_provider
  if [ "$MODE" = "interactive" ]; then
    sys_provider_interactive
  fi

  # 2) 探测（除非环境变量已全给 / --no-probe）
  local probe_skipped=0
  if [ "$NIX_INSTALL_URL" = "__skip__" ]; then
    NIX_INSTALL_URL=""
    probe_skipped=1
  fi
  if [ "$probe_skipped" = "0" ]; then
    if [ -z "$NIX_INSTALL_URL" ] || [ -z "$NIX_CHANNEL_URL" ] || [ -z "$NIX_SUBSTITUTERS" ]; then
      probe_run
      probe_report
      if [ "$MODE" = "interactive" ]; then
        probe_interactive
      fi
    fi
  fi

  # 若探测被跳过，仍然需要 channel
  if [ -z "$NIX_CHANNEL" ]; then
    NIX_CHANNEL=$(resolve_channel)
  fi
  if [ -z "$NIX_INSTALL_URL" ]; then
    NIX_INSTALL_URL="https://nixos.org/nix/install"
  fi
  if [ -z "$NIX_CHANNEL_URL" ]; then
    NIX_CHANNEL_URL="https://nixos.org/channels/$NIX_CHANNEL"
  fi
  if [ -z "$NIX_SUBSTITUTERS" ]; then
    NIX_SUBSTITUTERS="https://cache.nixos.org/"
  fi

  # 3) 系统信息（生成配置需要）
  prepare_sysinfo

  # 4) swap 检测（生成 hardware-configuration 需要 zramswap/swapcfg）
  checkExistingSwap

  # 5) 配置流程
  config_flow

  if [ "${DRY_RUN:-0}" = "1" ]; then
    log_info "$(msg dry_run_done)"
    log_info "  Generated config: $CONFIG_DIR/"
    log_info "  NIX_INSTALL_URL=$NIX_INSTALL_URL"
    log_info "  NIX_CHANNEL=$NIX_CHANNEL"
    log_info "  NIX_CHANNEL_URL=$NIX_CHANNEL_URL"
    log_info "  NIX_SUBSTITUTERS=$NIX_SUBSTITUTERS"
    exit 0
  fi

  # 6) 环境检查
  checkEnv

  # 7) swap
  if [ -z "$NO_SWAP" ] && [ "${zramswap:-true}" != "false" ]; then
    makeSwap
  fi

  # 8) /etc/nix/nix.conf
  write_nix_conf

  if [ -n "$NO_INFECT" ]; then
    log_info "NO_INFECT set, skipping installation"
    exit 0
  fi

  # 9) 安装 Nix + channel
  install_nix
  setup_channel

  # 10) 语法检查
  parse_check_loop

  # 11) 语义检查 + 构建
  semantic_check_loop

  # 12) 收尾
  finalize_nixos

  # 13) swap 清理
  if [ -z "$NO_SWAP" ] && [ "${zramswap:-true}" != "false" ]; then
    removeSwap
  fi

  log_info "$(msg install_done)"

  if [ -z "$NO_REBOOT" ]; then
    log_step "$(msg install_reboot)"
    reboot
  fi
}

# 只有直接运行时才调用 main（source 时不调用）
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi

