#!/usr/bin/env bash
# nix-mirror-probe.sh — 探测国内 Nix 镜像站覆盖情况，支持交互式选择镜像组合
# 只读操作，不修改系统配置
# 用法: ./nix-mirror-probe.sh [--lang en|zh] [--verbose] [--interactive] [--auto]

set -uo pipefail

# ===========================================================================
# 参数解析
# ===========================================================================
LANG_OPT="en"
VERBOSE=0
MODE="auto"   # auto | interactive
CHANNEL="nixos-25.11"

for arg in "$@"; do
  case "$arg" in
    --lang=zh|--lang=zh_CN) LANG_OPT="zh" ;;
    --lang=en) LANG_OPT="en" ;;
    --verbose) VERBOSE=1 ;;
    --interactive) MODE="interactive" ;;
    --auto) MODE="auto" ;;
    --channel=*) CHANNEL="${arg#*=}" ;;
    --help)
      cat <<'USAGE'
Usage: nix-mirror-probe.sh [OPTIONS]

Options:
  --lang=en|zh         Output language (default: en)
  --verbose            Show detailed per-mirror results
  --interactive        Ask user to choose mirrors per component
  --auto               Fully automatic recommendation (default)
  --channel=CHANNEL    NixOS channel to probe (default: nixos-25.11)
  --help               Show this help

Components:
  install   The Nix installer script URL
  channels  The nix-channel directory (for nix-channel --add)
  store     The binary cache (substituter) URL
USAGE
      exit 0
      ;;
  esac
done

# ===========================================================================
# 语言与输出
# ===========================================================================
if [ "$LANG_OPT" = "zh" ]; then
  T_TITLE="Nix 镜像站探测"
  T_PROBE_INSTALL="探测 Install 路径..."
  T_PROBE_CHANNEL="探测 Channels 路径..."
  T_PROBE_STORE="探测 Store 路径..."
  T_SPEED="测速中..."
  T_SUMMARY="探测结果汇总"
  T_RECOMMEND="推荐配置"
  T_MIXED="混合组合检查"
  T_INTERACTIVE="交互式配置"
  T_DONE="探测完成。"
  T_NO_CURL="错误：需要 curl，请先安装。"
  T_OK="可用"
  T_NOT_FOUND="未找到"
  T_UNREACHABLE="无法连接"
  T_FORBIDDEN="禁止访问"
  T_SPEED_NA="N/A"
else
  T_TITLE="Nix Mirror Probe"
  T_PROBE_INSTALL="Probing install paths..."
  T_PROBE_CHANNEL="Probing channels paths..."
  T_PROBE_STORE="Probing store paths..."
  T_SPEED="Speed test..."
  T_SUMMARY="Probe Summary"
  T_RECOMMEND="Recommended Configuration"
  T_MIXED="Mixed Combination Check"
  T_INTERACTIVE="Interactive Configuration"
  T_DONE="Probe complete."
  T_NO_CURL="Error: curl is required. Please install it first."
  T_OK="OK"
  T_NOT_FOUND="NOT_FOUND"
  T_UNREACHABLE="UNREACHABLE"
  T_FORBIDDEN="FORBIDDEN"
  T_SPEED_NA="N/A"
fi

# ===========================================================================
# 依赖检查
# ===========================================================================
if ! command -v curl >/dev/null 2>&1; then
  echo "$T_NO_CURL"
  exit 1
fi

# ===========================================================================
# 镜像站定义
# 格式: 名称|base_url|install_known_path
# install_known_path 为空表示需要自动探测
# ===========================================================================
MIRRORS=(
  "TUNA|https://mirrors.tuna.tsinghua.edu.cn|/nix/latest/install"
  "NJU|https://mirror.nju.edu.cn|/nix/latest/install"
  "USTC|https://mirrors.ustc.edu.cn|"
  "SJTUG|https://mirror.sjtu.edu.cn|"
  "BFSU|https://mirrors.bfsu.edu.cn|/nix/latest/install"
)

# install 路径的候选变体（用于没有已知路径的镜像站）
INSTALL_VARIANTS=(
  "/nix/latest/install"
  "/nix/install"
  "/nix/nix-installer/latest/install"
)

# 通道路径和 store 路径是统一的
CHANNEL_PATH="/nix-channels"
STORE_PATH="/nix-channels/store"

# 测速参数
SPEED_ROUNDS=3
CONNECT_TIMEOUT=5
MAX_TIME=20
RANGE_BYTES=524288   # 512KB，用于 range 请求

# 偏好权重：TUNA 优先。如果其他镜像速度超过 TUNA 的 PREFER_FACTOR 倍，则切换。
PREFER_FACTOR=2.0
PREFERRED_MIRROR="TUNA"

# ===========================================================================
# 工具函数
# ===========================================================================

# HEAD 请求，返回 HTTP 状态码
probe_http() {
  local url="$1"
  curl -sI -o /dev/null -w "%{http_code}" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -L "$url" 2>/dev/null || echo "000"
}

# 带 range 的测速，返回 "time_total speed_download time_connect"
speed_test_range() {
  local url="$1"
  curl -sL -r "0-$((RANGE_BYTES - 1))" -o /dev/null \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -w "%{time_total} %{speed_download} %{time_connect}" \
    "$url" 2>/dev/null || echo "0 0 0"
}

# 仅测连接延迟（用于 store，因为 store 下没有大文件）
speed_test_connect() {
  local url="$1"
  curl -sL -o /dev/null \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -w "%{time_connect}" \
    "$url" 2>/dev/null || echo "0"
}

# 多次测速取中位数速度
speed_median() {
  local url="$1"
  local -a speeds=()

  for _ in $(seq 1 "$SPEED_ROUNDS"); do
    local out
    out=$(speed_test_range "$url")
    local s
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

# 格式化速度
fmt_speed() {
  local bps="$1"
  if [ -z "$bps" ] || [ "$bps" = "0" ]; then
    echo "$T_SPEED_NA"
  elif [ "$bps" -ge 1048576 ] 2>/dev/null; then
    awk -v b="$bps" 'BEGIN{printf "%.1f MB/s", b/1048576}'
  elif [ "$bps" -ge 1024 ] 2>/dev/null; then
    awk -v b="$bps" 'BEGIN{printf "%.0f KB/s", b/1024}'
  else
    echo "${bps} B/s"
  fi
}

# HTTP 状态码转可读文本
fmt_status() {
  local code="$1"
  case "$code" in
    200|301|302|303|307|308) echo "$T_OK" ;;
    403) echo "$T_FORBIDDEN" ;;
    404) echo "$T_NOT_FOUND" ;;
    000) echo "$T_UNREACHABLE" ;;
    *)   echo "HTTP_$code" ;;
  esac
}

# 判断状态码是否表示可用
is_ok() {
  case "$1" in
    200|301|302|303|307|308) return 0 ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# 探测逻辑
# ===========================================================================

echo "=============================================="
echo "$T_TITLE"
echo "=============================================="
echo ""

# 存储探测结果
declare -A R_INSTALL_URL    # 名称 -> install URL
declare -A R_CHANNEL_SPEED  # 名称 -> channels 速度 (B/s)
declare -A R_STORE_SPEED    # 名称 -> store 速度 (B/s，复用 channels 速度或 0)
declare -A R_STORE_CONNECT  # 名称 -> store 连接延迟 (s)
declare -A R_CHANNEL_OK     # 名称 -> 1/0
declare -A R_STORE_OK       # 名称 -> 1/0

for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name base known_install <<< "$entry"
  echo "[$name] $base"

  # --- Install 探测 ---
  found_install=""
  if [ -n "$known_install" ]; then
    url="${base}${known_install}"
    code=$(probe_http "$url")
    if is_ok "$code"; then
      found_install="$url"
    fi
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
  [ "$VERBOSE" -eq 1 ] && echo "  install: ${found_install:-$T_NOT_FOUND}"

  # --- Channels 探测（具体文件，不是目录列表） ---
  channel_url="${base}${CHANNEL_PATH}/${CHANNEL}/nixexprs.tar.xz"
  code=$(probe_http "$channel_url")
  if is_ok "$code"; then
    R_CHANNEL_OK[$name]=1
    [ "$VERBOSE" -eq 1 ] && echo "  channels: $channel_url -> $T_OK"
    # 测速
    s=$(speed_median "$channel_url")
    R_CHANNEL_SPEED[$name]="$s"
    [ "$VERBOSE" -eq 1 ] && echo "  channels speed: $(fmt_speed "$s")"
  else
    R_CHANNEL_OK[$name]=0
    R_CHANNEL_SPEED[$name]="0"
    [ "$VERBOSE" -eq 1 ] && echo "  channels: $channel_url -> $(fmt_status "$code")"
  fi

  # --- Store 探测 ---
  store_info_url="${base}${STORE_PATH}/nix-cache-info"
  code=$(probe_http "$store_info_url")
  if is_ok "$code"; then
    R_STORE_OK[$name]=1
    # store 速度复用 channels 速度（同一镜像站网络路径相同）
    if [ "${R_CHANNEL_OK[$name]}" = "1" ]; then
      R_STORE_SPEED[$name]="${R_CHANNEL_SPEED[$name]}"
    else
      # channels 不可用时，单独测连接延迟
      c=$(speed_test_connect "$store_info_url")
      R_STORE_CONNECT[$name]="$c"
      R_STORE_SPEED[$name]="0"
    fi
    [ "$VERBOSE" -eq 1 ] && echo "  store: $store_info_url -> $T_OK, speed=${R_STORE_SPEED[$name]}"
  else
    R_STORE_OK[$name]=0
    R_STORE_SPEED[$name]="0"
    [ "$VERBOSE" -eq 1 ] && echo "  store: $store_info_url -> $(fmt_status "$code")"
  fi

  echo ""
done

# ===========================================================================
# 汇总表
# ===========================================================================
echo "=============================================="
echo "$T_SUMMARY"
echo "=============================================="
printf "%-8s %-14s %-14s %-14s %-12s\n" "Mirror" "Install" "Channels" "Store" "Ch Speed"
printf "%-8s %-14s %-14s %-14s %-12s\n" "------" "-------" "--------" "-----" "--------"

for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name _ _ <<< "$entry"
  inst="${R_INSTALL_URL[$name]:-}"
  inst_disp="${inst:-$T_NOT_FOUND}"
  # 缩短显示
  inst_disp=$(echo "$inst_disp" | sed 's|https://||; s|/nix/latest/install||; s|/nix/install||')

  ch_disp="$T_NOT_FOUND"
  [ "${R_CHANNEL_OK[$name]}" = "1" ] && ch_disp="$T_OK"

  st_disp="$T_NOT_FOUND"
  [ "${R_STORE_OK[$name]}" = "1" ] && st_disp="$T_OK"

  sp=$(fmt_speed "${R_CHANNEL_SPEED[$name]:-0}")

  printf "%-8s %-14s %-14s %-14s %-12s\n" "$name" "$inst_disp" "$ch_disp" "$st_disp" "$sp"
done
echo ""

# ===========================================================================
# 推荐逻辑
# ===========================================================================

# 选择 install：优先 TUNA（如果可用），否则按顺序选第一个可用的
recommend_install() {
  if [ -n "${R_INSTALL_URL[$PREFERRED_MIRROR]:-}" ]; then
    echo "$PREFERRED_MIRROR"
    return
  fi
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ -n "${R_INSTALL_URL[$name]:-}" ]; then
      echo "$name"
      return
    fi
  done
  echo ""
}

# 选择 channels：优先 TUNA，但如果其他镜像速度超过 TUNA 的 PREFER_FACTOR 倍，则切换
recommend_channel() {
  local tuna_speed="${R_CHANNEL_SPEED[$PREFERRED_MIRROR]:-0}"
  local best_name=""
  local best_speed=0

  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    [ "${R_CHANNEL_OK[$name]}" = "1" ] || continue
    s="${R_CHANNEL_SPEED[$name]:-0}"
    if [ "$s" -gt "$best_speed" ] 2>/dev/null; then
      best_speed="$s"
      best_name="$name"
    fi
  done

  if [ -z "$best_name" ]; then
    echo ""
    return
  fi

  # 如果 TUNA 可用且速度没有显著落后，用 TUNA
  if [ "${R_CHANNEL_OK[$PREFERRED_MIRROR]:-0}" = "1" ]; then
    if [ "$tuna_speed" -gt 0 ] 2>/dev/null; then
      local ratio
      ratio=$(awk -v bs="$best_speed" -v ts="$tuna_speed" 'BEGIN{ if(ts>0) print bs/ts; else print 0 }')
      if awk -v r="$ratio" -v f="$PREFER_FACTOR" 'BEGIN{exit !(r < f)}'; then
        echo "$PREFERRED_MIRROR"
        return
      fi
    else
      echo "$PREFERRED_MIRROR"
      return
    fi
  fi

  echo "$best_name"
}

# 选择 store：按速度排序，返回全量列表（用于 substituters）
recommend_store_list() {
  local -a items=()
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    [ "${R_STORE_OK[$name]}" = "1" ] || continue
    items+=("${R_STORE_SPEED[$name]:-0}:$name")
  done
  if [ ${#items[@]} -eq 0 ]; then
    return
  fi
  printf '%s\n' "${items[@]}" | sort -t: -k1 -rn | cut -d: -f2
}

BEST_INSTALL=$(recommend_install)
BEST_CHANNEL=$(recommend_channel)
BEST_STORE_LIST=$(recommend_store_list)

# ===========================================================================
# 交互模式
# ===========================================================================
if [ "$MODE" = "interactive" ]; then
  echo "=============================================="
  echo "$T_INTERACTIVE"
  echo "=============================================="

  # Install 选择
  echo ""
  echo "Available install mirrors:"
  local_i=0
  declare -a install_names=()
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ -n "${R_INSTALL_URL[$name]:-}" ]; then
      local_i=$((local_i + 1))
      install_names+=("$name")
      echo "  $local_i) $name  (${R_INSTALL_URL[$name]})"
    fi
  done
  echo "  $((local_i + 1))) none (use official installer)"
  echo -n "Choose install mirror [1-$((local_i + 1))] (default: auto=$BEST_INSTALL): "
  read -r choice
  if [ -n "$choice" ] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$local_i" ]; then
    BEST_INSTALL="${install_names[$((choice - 1))]}"
  fi

  # Channels 选择
  echo ""
  echo "Available channels mirrors:"
  local_j=0
  declare -a channel_names=()
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ "${R_CHANNEL_OK[$name]}" = "1" ]; then
      local_j=$((local_j + 1))
      channel_names+=("$name")
      echo "  $local_j) $name  (speed: $(fmt_speed "${R_CHANNEL_SPEED[$name]}"))"
    fi
  done
  echo "  $((local_j + 1))) none (use official channels)"
  echo -n "Choose channels mirror [1-$((local_j + 1))] (default: auto=$BEST_CHANNEL): "
  read -r choice
  if [ -n "$choice" ] && [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "$local_j" ]; then
    BEST_CHANNEL="${channel_names[$((choice - 1))]}"
  fi

  # Store 选择（多选，按顺序）
  echo ""
  echo "Available store mirrors (enter comma-separated names in priority order):"
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name _ _ <<< "$entry"
    if [ "${R_STORE_OK[$name]}" = "1" ]; then
      echo "  $name  (speed: $(fmt_speed "${R_STORE_SPEED[$name]}"))"
    fi
  done
  echo -n "Store order (default: auto): "
  read -r store_order
  if [ -n "$store_order" ]; then
    BEST_STORE_LIST=$(echo "$store_order" | tr ',' '\n')
  fi
fi

# ===========================================================================
# 输出推荐配置
# ===========================================================================
echo "=============================================="
echo "$T_RECOMMEND"
echo "=============================================="
echo ""

# Install URL
if [ -n "$BEST_INSTALL" ]; then
  echo "NIX_INSTALL_URL=${R_INSTALL_URL[$BEST_INSTALL]}"
else
  echo "NIX_INSTALL_URL=https://nixos.org/nix/install"
fi
echo ""

# Channel URL
if [ -n "$BEST_CHANNEL" ]; then
  echo "NIX_CHANNEL=${CHANNEL}"
  echo "NIX_CHANNEL_URL=https://mirror.${BEST_CHANNEL,,}.edu.cn/nix-channels/${CHANNEL}"
else
  echo "NIX_CHANNEL=${CHANNEL}"
  echo "NIX_CHANNEL_URL=https://nixos.org/channels/${CHANNEL}"
fi
echo ""

# Substituters 全量列表
echo "# substituters (ordered by speed, fastest first):"
subs_line="substituters ="
while IFS= read -r name; do
  [ -z "$name" ] && continue
  # 找到该名称的 base URL
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r mname mbase _ <<< "$entry"
    if [ "$mname" = "$name" ]; then
      subs_line="$subs_line ${mbase}${STORE_PATH}"
      break
    fi
  done
done <<< "$BEST_STORE_LIST"
subs_line="$subs_line https://cache.nixos.org/"
echo "$subs_line"
echo ""

# 同时输出 Nix 配置格式
echo "# For /etc/nix/nix.conf:"
echo "$subs_line"
echo ""
echo "# For configuration.nix:"
echo "nix.settings.substituters = ["
while IFS= read -r name; do
  [ -z "$name" ] && continue
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r mname mbase _ <<< "$entry"
    if [ "$mname" = "$name" ]; then
      echo "  \"${mbase}${STORE_PATH}\""
      break
    fi
  done
done <<< "$BEST_STORE_LIST"
echo "  \"https://cache.nixos.org/\""
echo "];"
echo ""

# ===========================================================================
# 混合组合检查
# ===========================================================================
echo "=============================================="
echo "$T_MIXED"
echo "=============================================="
echo ""

install_name="${BEST_INSTALL:-official}"
channel_name="${BEST_CHANNEL:-official}"

echo "  Install  : $install_name"
echo "  Channels : $channel_name"
echo "  Store    : $(echo "$BEST_STORE_LIST" | tr '\n' ' ')cache.nixos.org"
echo ""

# 检查：install 和 channels 是否来自同一镜像站
if [ "$install_name" != "$channel_name" ] && [ "$install_name" != "official" ] && [ "$channel_name" != "official" ]; then
  if [ "$LANG_OPT" = "zh" ]; then
    echo "  提示：Install 和 Channels 来自不同镜像站。"
    echo "  nixos-infect 中这两者是独立设置的，混合使用没有问题。"
    echo "  但请确保 install 脚本能成功运行，且 channel URL 可访问。"
  else
    echo "  Note: Install and Channels come from different mirrors."
    echo "  In nixos-infect, these are configured independently, so mixing is fine."
    echo "  Just ensure the install script runs successfully and the channel URL is reachable."
  fi
else
  if [ "$LANG_OPT" = "zh" ]; then
    echo "  所有组件来源一致或均为默认，无混合风险。"
  else
    echo "  All components come from the same mirror or use defaults. No mixing risk."
  fi
fi

echo ""
echo "$T_DONE"
