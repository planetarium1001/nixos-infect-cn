#!/usr/bin/env bash
# nix-mirror-probe.sh — 探测国内 Nix 镜像站可用性和下载速度
# 只读操作，不修改系统配置
# 用法: ./nix-mirror-probe.sh [--lang en|zh] [--verbose]

set -uo pipefail

# ---------------------------------------------------------------------------
# 语言与日志
# ---------------------------------------------------------------------------
LANG_OPT="en"
VERBOSE=0

for arg in "$@"; do
  case "$arg" in
    --lang=zh|--lang) LANG_OPT="zh" ;;
    --verbose) VERBOSE=1 ;;
    --help)
      echo "Usage: $0 [--lang en|zh] [--verbose]"
      exit 0
      ;;
  esac
done

msg() {
  local key="$1"; shift
  if [ "$LANG_OPT" = "zh" ]; then
    case "$key" in
      title)        echo "Nix 镜像站探测工具" ;;
      probe)        echo "探测路径存在性..." ;;
      speed)        echo "测速中..." ;;
      summary)      echo "探测结果汇总" ;;
      recommend)    echo "推荐配置" ;;
      done)         echo "探测完成。" ;;
      no_curl)      echo "错误：需要 curl，请先安装。" ;;
      *)            echo "$*" ;;
    esac
  else
    case "$key" in
      title)        echo "Nix Mirror Probe" ;;
      probe)        echo "Probing path availability..." ;;
      speed)        echo "Speed test..." ;;
      summary)      echo "Probe Summary" ;;
      recommend)    echo "Recommended Configuration" ;;
      done)         echo "Probe complete." ;;
      no_curl)      echo "Error: curl is required. Please install it first." ;;
      *)            echo "$*" ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# 依赖检查
# ---------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
  msg no_curl
  exit 1
fi

# ---------------------------------------------------------------------------
# 镜像站定义
# 格式: 名称|base_url|install_path|channel_path|store_path
# 路径为空表示该镜像站不提供此项，脚本会跳过
# ---------------------------------------------------------------------------
MIRRORS=(
  "TUNA|https://mirrors.tuna.tsinghua.edu.cn|/nix/latest/install|/nix-channels|/nix-channels/store"
  "NJU|https://mirror.nju.edu.cn||/nix-channels|/nix-channels/store"
  "USTC|https://mirrors.ustc.edu.cn||/nix-channels|/nix-channels/store"
  "SJTUG|https://mirror.sjtu.edu.cn||/nix-channels|/nix-channels/store"
  "BFSU|https://mirrors.bfsu.edu.cn||/nix-channels|/nix-channels/store"
)

# install 路径的变体（用于自动探测没有明确 install 路径的镜像站）
INSTALL_VARIANTS=(
  "/nix/latest/install"
  "/nix/install"
  "/nix/nix-installer/latest/install"
)

# 用于测速的小文件（相对于每个镜像站的 store 路径）
# nix-cache-info 是 binary cache 的元数据文件，通常几百字节
SPEED_TEST_FILE="nix-cache-info"

# 测速参数
SPEED_ROUNDS=3
CONNECT_TIMEOUT=5
MAX_TIME=15

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------

# 检查 URL 是否存在（HEAD 请求，跟随重定向）
# 返回 HTTP 状态码，000 表示连接失败
probe_http() {
  local url="$1"
  curl -sI -o /dev/null -w "%{http_code}" \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -L "$url" 2>/dev/null || echo "000"
}

# 测速：下载小文件，返回 "时间秒 速度字节/秒"
speed_test() {
  local url="$1"
  local result
  result=$(curl -sL -o /dev/null \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" \
    -w "%{time_total} %{speed_download}" \
    "$url" 2>/dev/null) || return 1
  echo "$result"
}

# 多次测速取中位数（按速度排序取中间值）
speed_median() {
  local url="$1"
  local -a times=() speeds=()

  for _ in $(seq 1 "$SPEED_ROUNDS"); do
    local out
    out=$(speed_test "$url") || continue
    local t s
    t=$(echo "$out" | awk '{print $1}')
    s=$(echo "$out" | awk '{print $2}')
    times+=("$t")
    speeds+=("$s")
  done

  local n=${#speeds[@]}
  if [ "$n" -eq 0 ]; then
    echo "0 0"
    return
  fi

  # 按速度排序
  local sorted
  sorted=$(printf '%s\n' "${speeds[@]}" | sort -n)
  local median_speed
  median_speed=$(echo "$sorted" | awk -v n="$n" 'NR==int((n+1)/2)')

  # 时间取对应轮次的，简单用平均值
  local median_time
  median_time=$(printf '%s\n' "${times[@]}" | awk '{s+=$1} END{printf "%.3f", s/NR}')

  echo "$median_time $median_speed"
}

# 格式化速度
fmt_speed() {
  local bytes_per_sec="$1"
  if [ "$bytes_per_sec" -eq 0 ] 2>/dev/null; then
    echo "N/A"
  elif [ "$bytes_per_sec" -ge 1048576 ]; then
    printf "%.1f MB/s" "$(echo "$bytes_per_sec / 1048576" | bc -l 2>/dev/null || echo "0")"
  elif [ "$bytes_per_sec" -ge 1024 ]; then
    printf "%.0f KB/s" "$(echo "$bytes_per_sec / 1024" | bc -l 2>/dev/null || echo "0")"
  else
    printf "%.0f B/s" "$bytes_per_sec"
  fi
}

# 格式化 HTTP 状态
fmt_status() {
  local code="$1"
  case "$code" in
    200|301|302|303|307|308) echo "OK" ;;
    403) echo "FORBIDDEN" ;;
    404) echo "NOT_FOUND" ;;
    000) echo "UNREACHABLE" ;;
    *)   echo "HTTP_$code" ;;
  esac
}

# ---------------------------------------------------------------------------
# 探测逻辑
# ---------------------------------------------------------------------------

msg title
echo "=============================================="
echo ""

declare -A RESULTS_INSTALL
declare -A RESULTS_CHANNEL
declare -A RESULTS_STORE
declare -A RESULTS_SPEED

for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name base install_path channel_path store_path <<< "$entry"
  echo "[$name] $base"

  # --- install 脚本 ---
  if [ -n "$install_path" ]; then
    url="${base}${install_path}"
    code=$(probe_http "$url")
    RESULTS_INSTALL[$name]="$(fmt_status "$code")"
    [ "$VERBOSE" -eq 1 ] && echo "  install : $url -> $(fmt_status "$code")"
  else
    # 自动探测 install 路径变体
    found=""
    for variant in "${INSTALL_VARIANTS[@]}"; do
      url="${base}${variant}"
      code=$(probe_http "$url")
      if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
        found="$variant"
        break
      fi
    done
    if [ -n "$found" ]; then
      RESULTS_INSTALL[$name]="OK"
      [ "$VERBOSE" -eq 1 ] && echo "  install : ${base}${found} -> OK"
    else
      RESULTS_INSTALL[$name]="NOT_FOUND"
      [ "$VERBOSE" -eq 1 ] && echo "  install : (no working path found)"
    fi
  fi

  # --- channels 目录 ---
  if [ -n "$channel_path" ]; then
    url="${base}${channel_path}/"
    code=$(probe_http "$url")
    RESULTS_CHANNEL[$name]="$(fmt_status "$code")"
    [ "$VERBOSE" -eq 1 ] && echo "  channels: $url -> $(fmt_status "$code")"
  else
    RESULTS_CHANNEL[$name]="N/A"
  fi

  # --- binary cache store ---
  if [ -n "$store_path" ]; then
    url="${base}${store_path}/${SPEED_TEST_FILE}"
    code=$(probe_http "$url")
    RESULTS_STORE[$name]="$(fmt_status "$code")"

    if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
      # 测速
      read -r t s <<< "$(speed_median "$url")"
      RESULTS_SPEED[$name]="$s"
      [ "$VERBOSE" -eq 1 ] && echo "  store   : $url -> $(fmt_speed "$s")"
    else
      RESULTS_SPEED[$name]="0"
      [ "$VERBOSE" -eq 1 ] && echo "  store   : $url -> $(fmt_status "$code")"
    fi
  else
    RESULTS_STORE[$name]="N/A"
    RESULTS_SPEED[$name]="0"
  fi

  echo ""
done

# ---------------------------------------------------------------------------
# 汇总输出
# ---------------------------------------------------------------------------
msg summary
echo "=============================================="
printf "%-8s %-12s %-12s %-12s %-12s\n" "Mirror" "Install" "Channels" "Store" "Speed"
printf "%-8s %-12s %-12s %-12s %-12s\n" "------" "-------" "--------" "-----" "-----"

for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name _ _ _ _ <<< "$entry"
  printf "%-8s %-12s %-12s %-12s %-12s\n" \
    "$name" \
    "${RESULTS_INSTALL[$name]:-N/A}" \
    "${RESULTS_CHANNEL[$name]:-N/A}" \
    "${RESULTS_STORE[$name]:-N/A}" \
    "$(fmt_speed "${RESULTS_SPEED[$name]:-0}")"
done

echo ""

# ---------------------------------------------------------------------------
# 推荐配置
# ---------------------------------------------------------------------------
msg recommend
echo "=============================================="

# 选 install 最快的（只考虑 install 可用的）
best_install=""
best_install_speed=0
for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name _ install_path _ _ <<< "$entry"
  [ "${RESULTS_INSTALL[$name]}" = "OK" ] || continue
  s="${RESULTS_SPEED[$name]:-0}"
  if [ "$s" -gt "$best_install_speed" ] 2>/dev/null; then
    best_install_speed="$s"
    best_install="$name"
  fi
done

# 选 store 最快的
best_store=""
best_store_speed=0
for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name _ _ _ _ <<< "$entry"
  [ "${RESULTS_STORE[$name]}" = "OK" ] || continue
  s="${RESULTS_SPEED[$name]:-0}"
  if [ "$s" -gt "$best_store_speed" ] 2>/dev/null; then
    best_store_speed="$s"
    best_store="$name"
  fi
done

# 输出推荐
if [ -n "$best_install" ]; then
  # 找到该镜像的 install URL
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name base install_path _ _ <<< "$entry"
    [ "$name" = "$best_install" ] || continue
    if [ -n "$install_path" ]; then
      echo "NIX_INSTALL_URL=${base}${install_path}"
    else
      # 回退到第一个可用变体
      for variant in "${INSTALL_VARIANTS[@]}"; do
        url="${base}${variant}"
        code=$(probe_http "$url")
        if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
          echo "NIX_INSTALL_URL=${url}"
          break
        fi
      done
    fi
  done
else
  echo "# No working install mirror found. Fallback to official:"
  echo "NIX_INSTALL_URL=https://nixos.org/nix/install"
fi

echo ""

if [ -n "$best_store" ]; then
  for entry in "${MIRRORS[@]}"; do
    IFS='|' read -r name base _ _ store_path <<< "$entry"
    [ "$name" = "$best_store" ] || continue
    echo "NIX_STORE_URL=${base}${store_path}"
  done
else
  echo "# No working store mirror found. Fallback to official:"
  echo "NIX_STORE_URL=https://cache.nixos.org"
fi

echo ""

# 输出 substituters 建议（包含前两名）
echo "# Recommended substituters (top-2 by speed):"
subs=""
declare -a sorted_mirrors=()
for entry in "${MIRRORS[@]}"; do
  IFS='|' read -r name _ _ _ _ <<< "$entry"
  [ "${RESULTS_STORE[$name]}" = "OK" ] || continue
  sorted_mirrors+=("${RESULTS_SPEED[$name]}:$name")
done
if [ ${#sorted_mirrors[@]} -gt 0 ]; then
  IFS=$'\n' sorted_mirrors=($(printf '%s\n' "${sorted_mirrors[@]}" | sort -rn))
  count=0
  for item in "${sorted_mirrors[@]}"; do
    [ "$count" -ge 2 ] && break
    mname="${item#*:}"
    for entry in "${MIRRORS[@]}"; do
      IFS='|' read -r name base _ _ store_path <<< "$entry"
      [ "$name" = "$mname" ] || continue
      subs="${subs} ${base}${store_path}"
    done
    count=$((count + 1))
  done
  echo "substituters =${subs} https://cache.nixos.org/"
fi

echo ""
msg done
