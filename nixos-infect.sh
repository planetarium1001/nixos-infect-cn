#! /usr/bin/env bash

# More info at: https://github.com/elitak/nixos-infect

set -e -o pipefail

# ===== 国内镜像配置 =====
# USTC、TUNA、NJU。
#   - channel/store：三个镜像都可用
#   - 安装器（install）：仅 TUNA/NJU 提供，USTC 自动跳过
# NIX_MIRROR=ustc|tuna|nju|auto|official
# 显式指定优先镜像，失败后自动尝试其余镜像。
declare -A MIRROR_BASES=(
  [ustc]="https://mirrors.ustc.edu.cn"
  [tuna]="https://mirrors.tuna.tsinghua.edu.cn"
  [nju]="https://mirror.nju.edu.cn"
)

MIRROR_ORDER=(tuna ustc nju)
# 安装器仅 TUNA 和 NJU 提供
INSTALLER_SUBSET=(tuna nju)
NIX_MIRROR="${NIX_MIRROR:-auto}"
NIX_CHANNEL="${NIX_CHANNEL:-nixos-26.05}"

MIRROR_TRY=()

if [[ "$NIX_MIRROR" == "official" ]]; then
  :
else
  if [[ "$NIX_MIRROR" != "auto" ]]; then
    if [[ -n "${MIRROR_BASES[$NIX_MIRROR]:-}" ]]; then
      MIRROR_TRY+=("$NIX_MIRROR")
    else
      echo "WARNING: 未知 NIX_MIRROR='$NIX_MIRROR'，回退 auto" >&2
    fi
  fi

  for m in "${MIRROR_ORDER[@]}"; do
    [[ " ${MIRROR_TRY[*]} " == *" $m "* ]] || MIRROR_TRY+=("$m")
  done
fi

mirror_install_url() {
  echo "${MIRROR_BASES[$1]}/nix/latest/install"
}

mirror_channel_url() {
  echo "${MIRROR_BASES[$1]}/nix-channels/$NIX_CHANNEL"
}

mirror_store_url() {
  echo "${MIRROR_BASES[$1]}/nix-channels/store"
}

install_nix() {
  if [[ -n "${NIX_INSTALL_URL:-}" ]]; then
    echo "使用显式 NIX_INSTALL_URL: $NIX_INSTALL_URL"
    curl -L "$NIX_INSTALL_URL" | sh -s -- --no-channel-add
    return 0
  fi

  if [[ ${#MIRROR_TRY[@]} -eq 0 ]]; then
    echo "使用官方 Nix 安装器"
    curl -L "https://nixos.org/nix/install" | sh -s -- --no-channel-add
    return 0
  fi

  local url
  for m in "${MIRROR_TRY[@]}"; do
    # 仅尝试已知提供安装器的镜像（USTC 无安装器）
    [[ " ${INSTALLER_SUBSET[*]} " == *" $m "* ]] || continue
    url="$(mirror_install_url "$m")"
    echo "尝试 Nix 安装器镜像: $m ($url)"
    if curl -fsSL "$url" | sh -s -- --no-channel-add; then
      echo "Nix 安装器镜像 $m 成功"
      return 0
    fi
    echo "WARNING: Nix 安装器镜像 $m 失败，尝试下一个" >&2
  done

  echo "所有镜像失败，回退官方 Nix 安装器" >&2
  curl -L "https://nixos.org/nix/install" | sh -s -- --no-channel-add
}

add_nix_channel() {
  nix-channel --remove nixpkgs || true

  if [[ ${#MIRROR_TRY[@]} -eq 0 ]]; then
    echo "使用官方 NixOS channel"
    nix-channel --add "https://nixos.org/channels/$NIX_CHANNEL" nixos
    nix-channel --update
    return 0
  fi

  for m in "${MIRROR_TRY[@]}"; do
    local url
    url="$(mirror_channel_url "$m")"
    echo "尝试 NixOS channel 镜像: $m ($url)"
    if nix-channel --add "$url" nixos && nix-channel --update; then
      echo "NixOS channel 镜像 $m 成功"
      return 0
    fi
    echo "WARNING: NixOS channel 镜像 $m 失败，尝试下一个" >&2
    nix-channel --remove nixos || true
  done

  echo "所有镜像失败，回退官方 channel" >&2
  nix-channel --add "https://nixos.org/channels/$NIX_CHANNEL" nixos
  nix-channel --update
}

write_nix_conf() {
  local nix_config=~/.config/nix
  mkdir -p "$nix_config"

  local substituters=()
  for m in "${MIRROR_TRY[@]}"; do
    substituters+=("$(mirror_store_url "$m")")
  done
  substituters+=("https://cache.nixos.org")

  {
    echo "substituters = ${substituters[*]}"
    echo "trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
  } > "$nix_config/nix.conf"
}
# ===== 国内镜像配置结束 =====

autodetectProvider() {
  if [ -e /etc/hetzner-build ]; then
    PROVIDER="hetznercloud"
  fi
}

makeConf() {
  # Skip everything if main config already present
  [[ -e /etc/nixos/configuration.nix ]] && return 0

  # Lightsail config is not like the others
  if [ "$PROVIDER" = "lightsail" ]; then
    makeLightsailConf
    return 0
  fi

  # NB <<"EOF" quotes / $ ` in heredocs, <<EOF does not
  mkdir -p /etc/nixos
  # Prevent grep for sending error code 1 (and halting execution) when no lines are selected : https://www.unix.com/man-page/posix/1P/grep
  local IFS=$'\n'

  local nix_substituters=""
  for m in "${MIRROR_TRY[@]}"; do
    nix_substituters+="    \"$(mirror_store_url "$m")\""
    nix_substituters+=$'\n'
  done
  nix_substituters+="    \"https://cache.nixos.org\""
  nix_substituters+=$'\n'

  local keys=""

  for trypath in /root/.ssh/authorized_keys /home/$SUDO_USER/.ssh/authorized_keys $HOME/.ssh/authorized_keys; do
      [[ -r "$trypath" ]] \
      && keys=$(sed -E 's/^[^#].*[[:space:]]((sk-ssh|sk-ecdsa|ssh|ecdsa)-[^[:space:]]+)[[:space:]]+([^[:space:]]+)([[:space:]]*.*)$/\1 \3\4/' "$trypath") \
      && [[ ! -z "$keys" ]] \
      && break
  done

  if [[ -z "${keys:-}" ]]; then
    echo "ERROR: 未找到任何 SSH 公钥，装完会无法登录。请先 ssh-copy-id。" >&2
    [[ -z "$NO_SWAP" ]] && removeSwap
    exit 1
  fi

  local network_import=""

  if [ "$PROVIDER" = "hostinger" ]; then
    kernel_params=$(cat << EOF
      boot.kernelParams = [
        "console=tty1"
        "console=ttyS0,115200"
      ];
EOF
    )
  else
    kernel_params=""
    fi

  [[ -n "$doNetConf" ]] && network_import="./networking.nix # generated at runtime by nixos-infect"

  local state_version="26.05"
  if [[ "$NIX_CHANNEL" =~ ^nixos-[0-9]+\.[0-9]+$ ]]; then
    state_version="${NIX_CHANNEL#nixos-}"
  fi

  cat > /etc/nixos/configuration.nix << EOF
{ ... }: {
  imports = [
    ./hardware-configuration.nix
    $network_import
    $NIXOS_IMPORT
  ];

  # Workaround for https://github.com/NixOS/nix/issues/8502
  services.logrotate.checkConfig = false;

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = ${zramswap};
  networking.hostName = "$(hostname -s)";
  networking.domain = "$(hostname -d)";
  services.openssh.enable = true;
  nix.settings.substituters = [
$nix_substituters  ];
  users.users.root.openssh.authorizedKeys.keys = [$(while read -r line; do
    line=$(echo -n "$line" | sed 's/\r//g')
    trimmed_line=$(echo -n "$line" | xargs)
    echo -n "''$trimmed_line'' "
  done <<< "$keys")];
  system.stateVersion = "$state_version";
  $kernel_params
}
EOF

  if isEFI; then
    if [[ $bootFs == /boot ]]; then
      bootcfg=$(cat << EOF
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  fileSystems."$bootFs" = { device = "$esp"; fsType = "vfat"; };
EOF
)
    else
      bootcfg=$(cat << EOF
  boot.loader = {
    efi.efiSysMountPoint = "/boot/efi";
    grub = {
      efiSupport = true;
      efiInstallAsRemovable = true;
      device = "nodev";
    };
  };
  fileSystems."$bootFs" = { device = "$esp"; fsType = "vfat"; };
EOF
)
    fi
  else
    bootcfg=$(cat << EOF
  boot.loader.grub.device = "$grubdev";
EOF
)
  fi


  availableKernelModules=('"ata_piix"' '"uhci_hcd"' '"xen_blkfront"')
  if isX86_64; then
    availableKernelModules+=('"vmw_pvscsi"')
  fi

  # If you rerun this later, be sure to prune the filesSystems attr
  cat > /etc/nixos/hardware-configuration.nix << EOF
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


  [[ -n "$doNetConf" ]] && makeNetworkingConf || true
}

makeLightsailConf() {
  mkdir -p /etc/nixos
  cat > /etc/nixos/configuration.nix << EOF
{ config, pkgs, modulesPath, lib, ... }:
{
  imports = [ "\${modulesPath}/virtualisation/amazon-image.nix" ];
  boot.loader.grub.device = lib.mkForce "/dev/nvme0n1";
}
EOF
    [[ -n "$doNetConf" ]] && makeNetworkingConf || true
}

makeNetworkingConf() {
  # XXX It'd be better if we used procfs for all this...
  local IFS=$'\n'
  eth0_name=$(ip address show | grep '^2:' | awk -F': ' '{print $2}')
  eth0_ip4s=$(ip address show dev "$eth0_name" | grep 'inet ' | sed -r 's|.*inet ([0-9.]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|')
  eth0_ip6s=$(ip address show dev "$eth0_name" | grep 'inet6 ' | sed -r 's|.*inet6 ([0-9a-f:]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|' || '')
  gateway=$(ip route show dev "$eth0_name" | grep default | sed -r 's|default via ([0-9.]+).*|\1|')
  gateway6=$(ip -6 route show dev "$eth0_name" | grep default | sed -r 's|default via ([0-9a-f:]+).*|\1|' || true)
  ether0=$(ip address show dev "$eth0_name" | grep link/ether | sed -r 's|.*link/ether ([0-9a-f:]+) .*|\1|')

  eth1_name=$(ip address show | grep '^3:' | awk -F': ' '{print $2}')||true
  if [ -n "$eth1_name" ];then
    eth1_ip4s=$(ip address show dev "$eth1_name" | grep 'inet ' | sed -r 's|.*inet ([0-9.]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|')
    eth1_ip6s=$(ip address show dev "$eth1_name" | grep 'inet6 ' | sed -r 's|.*inet6 ([0-9a-f:]+)/([0-9]+).*|{ address="\1"; prefixLength=\2; }|' || '')
    ether1=$(ip address show dev "$eth1_name" | grep link/ether | sed -r 's|.*link/ether ([0-9a-f:]+) .*|\1|')
    interfaces1=$(cat << EOF
      $eth1_name = {
        ipv4.addresses = [$(for a in "${eth1_ip4s[@]}"; do echo -n "
          $a"; done)
        ];
        ipv6.addresses = [$(for a in "${eth1_ip6s[@]}"; do echo -n "
          $a"; done)
        ];
        };
EOF
)
    extraRules1="ATTR{address}==\"${ether1}\", NAME=\"${eth1_name}\""
  else
    interfaces1=""
    extraRules1=""
  fi

  readarray nameservers < <(grep ^nameserver /etc/resolv.conf | sed -r \
    -e 's/^nameserver[[:space:]]+([0-9.a-fA-F:]+).*/"\1"/' \
    -e 's/127[0-9.]+/8.8.8.8/' \
    -e 's/::1/8.8.8.8/' )

  if [[ "$eth0_name" = eth* ]]; then
    predictable_inames="usePredictableInterfaceNames = lib.mkForce false;"
  else
    predictable_inames="usePredictableInterfaceNames = lib.mkForce true;"
  fi
  cat > /etc/nixos/networking.nix << EOF
{ lib, ... }: {
  # This file was populated at runtime with the networking
  # details gathered from the active system.
  networking = {
    nameservers = [ ${nameservers[@]} ];
    defaultGateway = "${gateway}";
    defaultGateway6 = {
      address = "${gateway6}";
      interface = "${eth0_name}";
    };
    dhcpcd.enable = false;
    $predictable_inames
    interfaces = {
      $eth0_name = {
        ipv4.addresses = [$(for a in "${eth0_ip4s[@]}"; do echo -n "
          $a"; done)
        ];
        ipv6.addresses = [$(for a in "${eth0_ip6s[@]}"; do echo -n "
          $a"; done)
        ];
        ipv4.routes = [ { address = "${gateway}"; prefixLength = 32; } ];
        ipv6.routes = [ { address = "${gateway6}"; prefixLength = 128; } ];
      };
      $interfaces1
    };
  };
  services.udev.extraRules = ''
    ATTR{address}=="${ether0}", NAME="${eth0_name}"
    $extraRules1
  '';
}
EOF
}

checkExistingSwap() {
  SWAPSHOW=$(swapon --show --noheadings --raw)
  zramswap=true
  swapcfg=""
  if [[ -n "$SWAPSHOW" ]]; then
    SWAP_DEVICE="${SWAPSHOW%% *}"
    if [[ "$SWAP_DEVICE" == "/dev/"* ]]; then
      zramswap=false
      swapcfg="swapDevices = [ { device = \"${SWAP_DEVICE}\"; } ];"
      NO_SWAP=true
    fi
  fi
}

makeSwap() {
  swapFile=$(mktemp /tmp/nixos-infect.XXXXX.swp)
  dd if=/dev/zero "of=$swapFile" bs=1M count=$((1*1024))
  chmod 0600 "$swapFile"
  mkswap "$swapFile"
  swapon -v "$swapFile"
}

removeSwap() {
  swapoff -a
  rm -vf /tmp/nixos-infect.*.swp
}

isX86_64() {
  [[ "$(uname -m)" == "x86_64" ]]
}

isEFI() {
  [ -d /sys/firmware/efi ]
}

findESP() {
  esp=""
  for d in /boot/EFI /boot/efi /boot; do
    [[ ! -d "$d" ]] && continue
    [[ "$d" == "$(df "$d" --output=target | sed 1d)" ]] \
      && esp="$(df "$d" --output=source | sed 1d)" \
      && break
  done
  [[ -z "$esp" ]] && { echo "WARNING: No ESP mount point found"; return 1; }
  for uuid in /dev/disk/by-uuid/*; do
    [[ $(readlink -f "$uuid") == "$esp" ]] && echo $uuid && return 0
  done
}

prepareEnv() {
  # $esp and $grubdev are used in makeConf()
  if isEFI; then
    esp="$(findESP)"
    if mount | grep -q /boot/efi; then
      bootFs=/boot/efi
    elif mount | grep -q /boot/EFI; then
      bootFs=/boot/EFI
    else
      bootFs=/boot
    fi
  else
    for grubdev in /dev/vda /dev/sda /dev/xvda /dev/nvme0n1 ; do [[ -e $grubdev ]] && break; done
  fi

  # Retrieve root fs block device
  #                   (get root mount)  (get partition or logical volume)
  rootfsdev=$(mount | grep "on / type" | awk '{print $1;}')
  rootfstype=$(df $rootfsdev --output=fstype | sed 1d)

  # DigitalOcean doesn't seem to set USER while running user data
  export USER="root"
  export HOME="/root"

  # Nix installer tries to use sudo regardless of whether we're already uid 0
  #which sudo || { sudo() { eval "$@"; }; export -f sudo; }
  # shellcheck disable=SC2174
  mkdir -p -m 0755 /nix
}

fakeCurlUsingWget() {
  # Use adapted wget if curl is missing
  which wget && { \
    curl() {
      eval "wget $(
        (local isStdout=1
        for arg in "$@"; do
          case "$arg" in
            "-o")
              echo "-O";
              isStdout=0
              ;;
            "-O")
              isStdout=0
              ;;
            "-L")
              ;;
            *)
              echo "$arg"
              ;;
          esac
        done;
        [[ $isStdout -eq 1 ]] && echo "-O-"
        )| tr '\n' ' '
      )"
    }; export -f curl; }
}

req() {
  type "$1" > /dev/null 2>&1 || which "$1" > /dev/null 2>&1
}

checkEnv() {
  [[ "$(whoami)" == "root" ]] || { echo "ERROR: Must run as root"; return 1; }

  # Perform some easy fixups before checking
  # TODO prevent multiple calls to apt-get update
  (which dnf && dnf install -y perl-Digest-SHA) || true # Fedora 24
  which bzcat || (which yum && yum install -y bzip2) \
              || (which apt-get && apt-get update && apt-get install -y bzip2) \
              || true
  which xzcat || (which yum && yum install -y xz) \
              || (which apt-get && apt-get update && apt-get install -y xz-utils) \
              || true
  which curl  || fakeCurlUsingWget \
              || (which apt-get && apt-get update && apt-get install -y curl) \
              || true
  which tar || (which yum && yum install -y tar) \
            || (which apt-get && apt-get update && apt-get install -y tar) \
            || true

  req curl || req wget || { echo "ERROR: Missing both curl and wget";  return 1; }
  req bzcat            || { echo "ERROR: Missing bzcat";               return 1; }
  req xzcat            || { echo "ERROR: Missing xzcat";               return 1; }
  req groupadd         || { echo "ERROR: Missing groupadd";            return 1; }
  req useradd          || { echo "ERROR: Missing useradd";             return 1; }
  req ip               || { echo "ERROR: Missing ip";                  return 1; }
  req awk              || { echo "ERROR: Missing awk";                 return 1; }
  req cut || req df    || { echo "ERROR: Missing coreutils (cut, df)"; return 1; }
  req tar              || { echo "ERROR: Missing tar";                 return 1; }

  # On some versions of Oracle Linux these have the wrong permissions,
  # which stops sshd from starting when NixOS boots
  chmod 600 /etc/ssh/ssh_host_*_key
}

infect() {
  # Add nix build users
  # FIXME run only if necessary, rather than defaulting true
  groupadd nixbld -g 30000 || true
  for i in {1..10}; do
    useradd -c "Nix build user $i" -d /var/empty -g nixbld -G nixbld -M -N -r -s "$(which nologin)" "nixbld$i" || true
  done
  # TODO use addgroup and adduser as fallbacks
  #addgroup nixbld -g 30000 || true
  #for i in {1..10}; do adduser -DH -G nixbld nixbld$i || true; done
  install_nix

  # shellcheck disable=SC1090
  source ~/.nix-profile/etc/profile.d/nix.sh

  add_nix_channel
  write_nix_conf

  if [[ $NIXOS_CONFIG = http* ]]
  then
    curl -L $NIXOS_CONFIG -o /etc/nixos/configuration.nix
    unset NIXOS_CONFIG
  fi

  export NIXOS_CONFIG="${NIXOS_CONFIG:-/etc/nixos/configuration.nix}"

  nix-env --set \
    -I nixpkgs=$(realpath $HOME/.nix-defexpr/channels/nixos) \
    -f '<nixpkgs/nixos>' \
    -p /nix/var/nix/profiles/system \
    -A system

  # Remove nix installed with curl | bash
  rm -fv /nix/var/nix/profiles/default*
  /nix/var/nix/profiles/system/sw/bin/nix-collect-garbage

  # Reify resolv.conf
  [[ -L /etc/resolv.conf ]] && mv -v /etc/resolv.conf /etc/resolv.conf.lnk && cat /etc/resolv.conf.lnk > /etc/resolv.conf

  # Set label of root partition
  if [ -n "$newrootfslabel" ]; then
    echo "Setting label of $rootfsdev to $newrootfslabel"
    e2label "$rootfsdev" "$newrootfslabel"
  fi

  # Stage the Nix coup d'état
  touch /etc/NIXOS
  echo etc/nixos                  >> /etc/NIXOS_LUSTRATE
  echo etc/resolv.conf            >> /etc/NIXOS_LUSTRATE
  echo root/.nix-defexpr/channels >> /etc/NIXOS_LUSTRATE
  (cd / && ls etc/ssh/ssh_host_*_key* || true) >> /etc/NIXOS_LUSTRATE

  if isEFI; then
    rm -rf $bootFs.bak
    umount "$esp"
    mv -v $bootFs $bootFs.bak || { cp -a $bootFs $bootFs.bak ; rm -rf $bootFs/* ; umount $bootFs ; }
    mkdir -p $bootFs
    mount "$esp" $bootFs
    find $bootFs -depth ! -path $bootFs -exec rm -rf {} +
  fi
  /nix/var/nix/profiles/system/bin/switch-to-configuration boot
}

if [ ! -v PROVIDER ]; then
  autodetectProvider
fi

[ "$PROVIDER" = "lightsail" ] && newrootfslabel="nixos"
if [[ "$PROVIDER" = "digitalocean" ]] || [[ "$PROVIDER" = "servarica" ]] || [[ "$PROVIDER" = "hetznercloud" ]] || [[ "$PROVIDER" = "webdock" ]] || [[ "$PROVIDER" = "layer7" ]] || [[ "$PROVIDER" = "hostinger" ]]; then
	doNetConf=y # some providers require detailed network config to be generated
fi

checkEnv
prepareEnv
checkExistingSwap
if [[ -z "$NO_SWAP" ]]; then
    makeSwap # smallest (512MB) droplet needs extra memory!
fi
makeConf
if [[ -z "$NO_INFECT" ]]; then
    infect
fi
if [[ -z "$NO_SWAP" ]]; then
    removeSwap
fi

if [[ -z "$NO_REBOOT" ]]; then
  reboot
fi
