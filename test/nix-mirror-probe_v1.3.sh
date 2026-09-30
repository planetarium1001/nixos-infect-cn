#!/usr/bin/env bash
# nix-mirror-probe.sh v1.3
# 探测国内 Nix 镜像站覆盖情况，支持交互式选择镜像组合
# 只读操作，不修改系统配置
# 用法: ./nix-mirror-probe.sh [OPTIONS]

set -uo pipefail

# ===========================================================================
# 参数解析
# ===========================================================================
LANG_OPT="en"
VERBOSE=0
MODE="auto"
CHANNEL="nixos-25.11"
PREFER_MIRROR=""
NO_COLOR="${NO_COLOR:-}"

for arg in "$@"; do
  case "$arg" in
    --lang=zh|--lang=zh_CN|--lang=zh_TW) LANG_OPT="zh" ;;
    --lang=en) LANG_OPT="en" ;;
    --verbose) VERBOSE=1 ;;
    --interactive) MODE="interactive" ;;
    --auto) MODE="auto" ;;
    --channel=*) CHANNEL="${arg#*=}" ;;
    --prefer=*) PREFER_MIRROR="${arg#*=}" ;;
    --no-color) NO_COLOR=1 ;;
    --help)
      cat <<'USAGE'
Usage: nix-mirror-probe.sh [OPTIONS]

Options:
  --lang=en|zh         Output language (default: en)
  --verbose            Show detailed per-mirror results
  --interactive        Ask user to choose mirrors per component
  --auto               Fully automatic recommendation (default)
  --channel=CHANNEL    NixOS channel to probe (default: nixos-25.11)
  --prefer=NAME        Prefer this mirror if available (e.g. TUNA)
  --no-color           Disable colored output
  --help               Show this help

Components:
  install   Nix installer script URL
  channels  nix-channel directory (for nix-channel --add)
  store     Binary cache (substituter) URL
USAGE
      exit 0
      ;;
  esac
done

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
# 语言
# ===========================================================================
if [ "$LANG_OPT" = "zh" ]; then
  T_TITLE="Nix 镜像站探测"
  T_SUMMARY="探测结果汇总"
  T_RECOMMEND="推荐配置"
  T_INTERACTIVE="交互式配置"
  T_MIXED="组合检查"
  T_DONE="探测完成。"
  T_NO_CURL="错误：需要 curl，请先安装。"
  T_OK="OK"
  T_NOT_FOUND="NOT_FOUND"
  T_NA="N/A"
  T_OFFICIAL="官方"
  T_ALL_SAME="所有组件来源一致，无混合风险。"
  T_MIXED_NOTE="Install 与 Channels 来自不同镜像站，nixos-infect 中这两者独立设置，混合使用正常。"
  T_PROMPT_INSTALL="选择 Install 镜像"
  T_PROMPT_CHANNEL="选择 Channels 镜像"
  T_PROMPT_STORE="选择 Store 镜像顺序（输入编号，逗号分隔）"
  T_DEFAULT="默认"
  T_DEFAULT_ORDER="默认顺序"
else
  T_TITLE="Nix Mirror Probe"
  T_SUMMARY="Probe Summary"
  T_RECOMMEND="Recommended Configuration"
  T_INTERACTIVE="Interactive Configuration"
  T_MIXED="Combination Check"
  T_DONE="Probe complete."
  T_NO_CURL="Error: curl is required. Please install it first."
  T_OK="OK"
  T_NOT_FOUND="NOT_FOUND"
  T_NA="N/A"
  T_OFFICIAL="official"
  T_ALL_SAME="All components come from the same mirror. No mixing risk."
  T_MIXED_NOTE="Install and Channels come from different mirrors. In nixos-infect these are configured independently, so mixing is fine."
  T_PROMPT_INSTALL="Choose install mirror"
  T_PROMPT_CHANNEL="Choose channels mirror"
  T_PROMPT_STORE="Choose store order (comma-separated numbers)"
  T_DEFAULT="default"
  T_DEFAULT_ORDER="Default order"
fi

# ===========================================================================
# 依赖
# ===========================================================================
if ! command -v curl >/dev/null 2>&1; then
  echo "$T_NO_CURL"
  exit 1
fi

# ===========================================================================
# 镜像站定义
# ===========================================================================
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

SPEED_ROUNDS=3
CONNECT_TIMEOUT=5
MAX_TIME=20
RANGE_BYTES=524288

# ===========================================================================
# 工具函数
# ===========================================================================
probe_http() {
  local url="$1"
  curl -sI -o /dev/null -w "%{http_code}" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -L "$url" 2>/dev/null || echo "000"
}

speed_test_range() {
  local url="$1"
  curl -sL -r "0-$((RANGE_BYTES - 1))" -o /dev/null \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -w "%{time_total} %{speed_download}" \
    "$url" 2>/dev/null || echo "0 0"
}

speed_median() {
  local url="$1"
  local -a speeds=()
  for _ in $(seq 1 "$SPEED_ROUNDS"); do
    local out s
    out=$(speed_test_range "$url")
    s=$(echo "$out" | awk '{print $2}')
    [ -n "$s" ] && speeds+=("$s")
  done
  local n=${#speeds[@]}
  if [ "$n" -eq 0 ]; then
    echo "0"
    return
  fi
  printf '%s\n' "${speeds[@]}" | sort -n | awk -v n="$n" 'NR==int((n+1)/2)'
}

fmt_speed_raw() {
  local bps="$1"
  if [ -z "$bps" ] || [ "$bps" = "0" ]; then
    echo "$T_NA"
  elif [ "$bps" -ge 1048576 ] 2>/dev/null; then
    awk -v b="$bps" 'BEGIN{printf "%.1f MB/s", b/1048576}'
  elif [ "$bps" -ge 1024 ] 2>/dev/null; then
    awk -v b="$bps" 'BEGIN{printf "%.0f KB/s", b/1024}'
  else
    echo "${bps} B/s"
  fi
}

# 带颜色的速度
fmt_speed() {
  local bps="$1"
  local text
  text=$(fmt_speed_raw "$bps")
  if [ -z "$bps" ] || [ "$bps" = "0" ]; then
    echo "${C_DIM}${text}${C_RESET}"
  elif [ "$bps" -ge 1048576 ] 2>/dev/null; then
    echo "${C_GREEN}${text}${C_RESET}"
  elif [ "$bps" -ge 307200 ] 2>/dev/null; then
    echo "${C_YELLOW}${text}${C_RESET}"
  else
    echo "${C_RED}${text}${C_RESET}"
  fi
}

fmt_status() {
  local code="$1"
  case "$code" in
    200|301|302|303|307|308) echo "$T_OK" ;;
    403) echo "FORBIDDEN" ;;
    404) echo "$T_NOT_FOUND" ;;
    000) echo "UNREACHABLE" ;;
    *)   echo "HTTP_$code" ;;
  esac
}

is_ok() {
  case "$1" in
    200|301|302|303|307|308) return 0 ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# 探测
# ===========================================================================
echo "${C_BLUE}==============================================${C_RESET}"
echo "${C_BOLD}${C_BLUE}${T_TITLE}${C_RESET}"
echo "${C_BLUE}==============================================${C_RESET}"
echo ""

declare -A R_INSTALL_URL
declare -A R_CHANNEL_URL
declare -A R_CHANNEL_SPEED
declare -A R_STORE_URL
declare -A R_STORE_SPEED
declare -A R_CHANNEL_OK
declare -A R_STORE_OK

for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name base known_install <<< "$entry"
  echo "${C_CYAN}[$name]${C_RESET} ${C_DIM}$base${C_RESET}"

  # --- Install ---
  found_install=""
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
  R_INSTALL_URL[$name]="${found_install:-}"
  if [ "$VERBOSE" -eq 1 ]; then
    if [ -n "$found_install" ]; then
      echo "  install : ${C_GREEN}${T_OK}${C_RESET}  $found_install"
    else
      echo "  install : ${C_RED}${T_NOT_FOUND}${C_RESET}"
    fi
  fi

  # --- Channels ---
  channel_url="${base}${CHANNEL_PATH}/${CHANNEL}"
  channel_test_url="${channel_url}/nixexprs.tar.xz"
  code=$(probe_http "$channel_test_url")
  if is_ok "$code"; then
    R_CHANNEL_OK[$name]=1
    R_CHANNEL_URL[$name]="$channel_url"
    s=$(speed_median "$channel_test_url")
    R_CHANNEL_SPEED[$name]="$s"
    [ "$VERBOSE" -eq 1 ] && echo "  channels: ${C_GREEN}${T_OK}${C_RESET}  $(fmt_speed "$s")  $channel_url"
  else
    R_CHANNEL_OK[$name]=0
    R_CHANNEL_URL[$name]=""
    R_CHANNEL_SPEED[$name]="0"
    [ "$VERBOSE" -eq 1 ] && echo "  channels: ${C_RED}$(fmt_status "$code")${C_RESET}  $channel_test_url"
  fi

  # --- Store ---
  store_url="${base}${STORE_PATH}"
  store_test_url="${store_url}/nix-cache-info"
  code=$(probe_http "$store_test_url")
  if is_ok "$code"; then
    R_STORE_OK[$name]=1
    R_STORE_URL[$name]="$store_url"
    R_STORE_SPEED[$name]="${R_CHANNEL_SPEED[$name]}"
    [ "$VERBOSE" -eq 1 ] && echo "  store   : ${C_GREEN}${T_OK}${C_RESET}  $store_url"
  else
    R_STORE_OK[$name]=0
    R_STORE_URL[$name]=""
    R_STORE_SPEED[$name]="0"
    [ "$VERBOSE" -eq 1 ] && echo "  store   : ${C_RED}$(fmt_status "$code")${C_RESET}  $store_test_url"
  fi

  echo ""
done

# ===========================================================================
# 汇总表（纯文本，不含颜色代码，保证对齐）
# ===========================================================================
echo "${C_BLUE}==============================================${C_RESET}"
echo "${C_BOLD}${C_BLUE}${T_SUMMARY}${C_RESET}"
echo "${C_BLUE}==============================================${C_RESET}"
printf "${C_BOLD}%-8s %-13s %-13s %-13s %-12s${C_RESET}\n" "Mirror" "Install" "Channels" "Store" "Ch Speed"
printf "${C_DIM}%-8s %-13s %-13s %-13s %-12s${C_RESET}\n" "------" "-------" "--------" "-----" "--------"

for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name _ _ <<< "$entry"
  inst="$T_NOT_FOUND"
  [ -n "${R_INSTALL_URL[$name]:-}" ] && inst="$T_OK"

  ch="$T_NOT_FOUND"
  [ "${R_CHANNEL_OK[$name]:-0}" = "1" ] && ch="$T_OK"

  st="$T_NOT_FOUND"
  [ "${R_STORE_OK[$name]:-0}" = "1" ] && st="$T_OK"

  sp=$(fmt_speed_raw "${R_CHANNEL_SPEED[$name]:-0}")

  printf "%-8s %-13s %-13s %-13s %-12s\n" "$name" "$inst" "$ch" "$st" "$sp"
done
echo ""

# ===========================================================================
# 自动推荐
# ===========================================================================

# 速度指标：用 channels 速度代表该镜像站整体性能
mirror_metric() {
  echo "${R_CHANNEL_SPEED[$1]:-0}"
}

# 从候选镜像中按速度选出最佳
pick_best() {
  local kind="$1"
  local best_name=""
  local best_speed=-1
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    local available=0
    case "$kind" in
      install) [ -n "${R_INSTALL_URL[$name]:-}" ] && available=1 ;;
      channel) [ "${R_CHANNEL_OK[$name]:-0}" = "1" ] && available=1 ;;
    esac
    [ "$available" = "1" ] || continue
    local s
    s=$(mirror_metric "$name")
    if [ "$s" -gt "$best_speed" ] 2>/dev/null; then
      best_speed="$s"
      best_name="$name"
    fi
  done
  echo "$best_name"
}

# 优先使用 --prefer 指定的镜像（如果可用），否则按速度
pick_with_preference() {
  local kind="$1"
  if [ -n "$PREFER_MIRROR" ]; then
    local preferred_ok=0
    case "$kind" in
      install) [ -n "${R_INSTALL_URL[$PREFER_MIRROR]:-}" ] && preferred_ok=1 ;;
      channel) [ "${R_CHANNEL_OK[$PREFER_MIRROR]:-0}" = "1" ] && preferred_ok=1 ;;
    esac
    if [ "$preferred_ok" = "1" ]; then
      echo "$PREFER_MIRROR"
      return
    fi
  fi
  pick_best "$kind"
}

# 返回按速度排序的 store 镜像站名字列表（每行一个）
pick_store_list() {
  local -a items=()
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    [ "${R_STORE_OK[$name]:-0}" = "1" ] || continue
    items+=("${R_CHANNEL_SPEED[$name]:-0}:$name")
  done
  [ ${#items[@]} -eq 0 ] && return
  printf '%s\n' "${items[@]}" | sort -t: -k1 -rn | cut -d: -f2
}

BEST_INSTALL=$(pick_with_preference install)
BEST_CHANNEL=$(pick_with_preference channel)
BEST_STORE_LIST=$(pick_store_list)

# ===========================================================================
# 交互模式
# ===========================================================================
if [ "$MODE" = "interactive" ]; then
  echo "${C_BLUE}==============================================${C_RESET}"
  echo "${C_BOLD}${C_BLUE}${T_INTERACTIVE}${C_RESET}"
  echo "${C_BLUE}==============================================${C_RESET}"
  echo ""

  # ---------- Install ----------
  echo "${C_MAGENTA}[ $T_PROMPT_INSTALL ]${C_RESET}"
  install_names=()
  idx=0
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ -n "${R_INSTALL_URL[$name]:-}" ]; then
      idx=$((idx + 1))
      install_names+=("$name")
      printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} ${C_DIM}%s${C_RESET}\n" \
        "$idx" "$name" "${R_INSTALL_URL[$name]}"
    fi
  done
  idx=$((idx + 1))
  install_names+=("__official__")
  printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} ${C_DIM}%s${C_RESET}\n" \
    "$idx" "$T_OFFICIAL" "https://nixos.org/nix/install"

  default_idx=1
  for i in "${!install_names[@]}"; do
    if [ "${install_names[$i]}" = "$BEST_INSTALL" ]; then
      default_idx=$((i + 1))
      break
    fi
  done

  printf "%s [1-%d] ${C_YELLOW}(%s: %d=%s)${C_RESET}: " \
    "$T_PROMPT_INSTALL" "$idx" "$T_DEFAULT" "$default_idx" "${install_names[$((default_idx - 1))]}"
  read -r choice
  [ -z "$choice" ] && choice="$default_idx"
  if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$idx" ]; then
    BEST_INSTALL="${install_names[$((choice - 1))]}"
  fi
  echo ""

  # ---------- Channels ----------
  echo "${C_MAGENTA}[ $T_PROMPT_CHANNEL ]${C_RESET}"
  channel_names=()
  idx=0
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ "${R_CHANNEL_OK[$name]:-0}" = "1" ]; then
      idx=$((idx + 1))
      channel_names+=("$name")
      printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} %s\n" \
        "$idx" "$name" "$(fmt_speed "${R_CHANNEL_SPEED[$name]}")"
    fi
  done
  idx=$((idx + 1))
  channel_names+=("__official__")
  printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} ${C_DIM}%s${C_RESET}\n" \
    "$idx" "$T_OFFICIAL" "https://nixos.org/channels/${CHANNEL}"

  default_idx=1
  for i in "${!channel_names[@]}"; do
    if [ "${channel_names[$i]}" = "$BEST_CHANNEL" ]; then
      default_idx=$((i + 1))
      break
    fi
  done

  printf "%s [1-%d] ${C_YELLOW}(%s: %d=%s)${C_RESET}: " \
    "$T_PROMPT_CHANNEL" "$idx" "$T_DEFAULT" "$default_idx" "${channel_names[$((default_idx - 1))]}"
  read -r choice
  [ -z "$choice" ] && choice="$default_idx"
  if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$idx" ]; then
    BEST_CHANNEL="${channel_names[$((choice - 1))]}"
  fi
  echo ""

  # ---------- Store ----------
  echo "${C_MAGENTA}[ $T_PROMPT_STORE ]${C_RESET}"
  store_names=()
  idx=0
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ "${R_STORE_OK[$name]:-0}" = "1" ]; then
      idx=$((idx + 1))
      store_names+=("$name")
      printf "  ${C_BOLD}%2d)${C_RESET} ${C_CYAN}%-8s${C_RESET} %s\n" \
        "$idx" "$name" "$(fmt_speed "${R_STORE_SPEED[$name]}")"
    fi
  done

  # 默认顺序：按 BEST_STORE_LIST 转成编号，同时生成名字序列
  default_order=""
  default_names=""
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
  done <<< "$BEST_STORE_LIST"

  echo "  ${C_YELLOW}${T_DEFAULT_ORDER}: ${default_order} = ${default_names}${C_RESET}"
  printf "%s ${C_YELLOW}(%s: %s)${C_RESET}: " \
    "$T_PROMPT_STORE" "$T_DEFAULT" "$default_order"
  read -r store_order
  [ -z "$store_order" ] && store_order="$default_order"

  new_store_list=""
  while IFS= read -r token; do
    token=$(echo "$token" | tr -d ' ')
    [ -z "$token" ] && continue
    if [ "$token" -ge 1 ] 2>/dev/null && [ "$token" -le "$idx" ]; then
      new_store_list="${new_store_list}${store_names[$((token - 1))]}"$'\n'
    fi
  done <<< "$(echo "$store_order" | tr ',' '\n')"
  BEST_STORE_LIST="$new_store_list"
  echo ""
fi

# ===========================================================================
# 输出推荐配置
# ===========================================================================
echo "${C_BLUE}==============================================${C_RESET}"
echo "${C_BOLD}${C_BLUE}${T_RECOMMEND}${C_RESET}"
echo "${C_BLUE}==============================================${C_RESET}"
echo ""

# Install URL
if [ -n "$BEST_INSTALL" ] && [ "$BEST_INSTALL" != "__official__" ]; then
  echo "${C_GREEN}NIX_INSTALL_URL${C_RESET}=${R_INSTALL_URL[$BEST_INSTALL]}"
else
  echo "${C_GREEN}NIX_INSTALL_URL${C_RESET}=https://nixos.org/nix/install"
fi
echo ""

# Channel URL
echo "${C_GREEN}NIX_CHANNEL${C_RESET}=${CHANNEL}"
if [ -n "$BEST_CHANNEL" ] && [ "$BEST_CHANNEL" != "__official__" ]; then
  echo "${C_GREEN}NIX_CHANNEL_URL${C_RESET}=${R_CHANNEL_URL[$BEST_CHANNEL]}"
else
  echo "${C_GREEN}NIX_CHANNEL_URL${C_RESET}=https://nixos.org/channels/${CHANNEL}"
fi
echo ""

# Substituters 全量列表
echo "${C_DIM}# substituters, ordered by speed (fastest first)${C_RESET}"
subs_line="substituters ="
while IFS= read -r name; do
  [ -z "$name" ] && continue
  [ -n "${R_STORE_URL[$name]:-}" ] || continue
  subs_line="$subs_line ${R_STORE_URL[$name]}"
done <<< "$BEST_STORE_LIST"
subs_line="$subs_line https://cache.nixos.org/"
echo "${C_GREEN}${subs_line}${C_RESET}"
echo ""

# configuration.nix 格式
echo "${C_DIM}# For /etc/nixos/configuration.nix:${C_RESET}"
echo "nix.settings.substituters = ["
while IFS= read -r name; do
  [ -z "$name" ] && continue
  [ -n "${R_STORE_URL[$name]:-}" ] || continue
  echo "  \"${R_STORE_URL[$name]}\""
done <<< "$BEST_STORE_LIST"
echo "  \"https://cache.nixos.org/\""
echo "];"
echo ""

# ===========================================================================
# 组合检查
# ===========================================================================
echo "${C_BLUE}==============================================${C_RESET}"
echo "${C_BOLD}${C_BLUE}${T_MIXED}${C_RESET}"
echo "${C_BLUE}==============================================${C_RESET}"
echo ""

install_disp="$T_OFFICIAL"
[ -n "$BEST_INSTALL" ] && [ "$BEST_INSTALL" != "__official__" ] && install_disp="$BEST_INSTALL"

channel_disp="$T_OFFICIAL"
[ -n "$BEST_CHANNEL" ] && [ "$BEST_CHANNEL" != "__official__" ] && channel_disp="$BEST_CHANNEL"

# 清理尾部换行，避免双空格
store_disp=$(echo "$BEST_STORE_LIST" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
if [ -n "$store_disp" ]; then
  store_disp="$store_disp cache.nixos.org"
else
  store_disp="cache.nixos.org"
fi

printf "  %-9s: ${C_CYAN}%s${C_RESET}\n" "Install" "$install_disp"
printf "  %-9s: ${C_CYAN}%s${C_RESET}\n" "Channels" "$channel_disp"
printf "  %-9s: ${C_CYAN}%s${C_RESET}\n" "Store" "$store_disp"
echo ""

if [ "$install_disp" = "$channel_disp" ] || [ "$install_disp" = "$T_OFFICIAL" ] || [ "$channel_disp" = "$T_OFFICIAL" ]; then
  echo "  ${C_GREEN}${T_ALL_SAME}${C_RESET}"
else
  echo "  ${C_YELLOW}${T_MIXED_NOTE}${C_RESET}"
fi

echo ""
echo "${C_GREEN}${T_DONE}${C_RESET}"
