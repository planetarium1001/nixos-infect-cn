#!/usr/bin/env bash
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
    NIX_SUBSTITUTERS="$subs"
  else
    NIX_SUBSTITUTERS=""
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
