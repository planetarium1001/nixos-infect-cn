#!/usr/bin/env bash
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
    # NixOS 会自动追加 cache.nixos.org，跳过以免重复
    [ "$url" = "https://cache.nixos.org/" ] && continue
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
