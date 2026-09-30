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
