# 配置定制

本文说明生成的配置从哪里来、三种修改方式、全部占位符，以及常见定制写法。
目标是让你在安装前就把 `/etc/nixos` 调整成自己想要的样子。

## 配置从哪里来

- 默认继承原系统的主机名（`hostname -s`）与域名（`hostname -d`）。
- 生成 `configuration.nix` 和 `hardware-configuration.nix`；识别到静态网络时再加 `networking.nix`。
- 默认启用 OpenSSH、`boot.tmp.cleanOnBoot`、zram swap，写入 `system.defaultChannel` 与国内 substituters。
- root 的公钥依次从 `/root/.ssh/authorized_keys`、`/home/$SUDO_USER/.ssh/authorized_keys`、`$HOME/.ssh/authorized_keys` 收集。
- 默认包：`vim`、`git`、`curl`、`wget`、`htop`、`tmux`；`system.stateVersion = "25.11"`。
- 有真实 swap 分区时改为 `swapDevices`，不再启用 zram；配置中不写入 `cache.nixos.org`。

## 方式一：交互模式

**想改 Nix 文件就用交互模式**；管道执行没有终端，所有提问取默认值。编辑 `hardware-configuration.nix` 会直接影响引导，不清楚后果时不要改。

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/planetarium1001/nixos-infect-cn@master/nixos-infect.sh -o nixos-infect.sh
bash nixos-infect.sh --interactive --lang=zh
```

流程共五步：

- 探测镜像并显示汇总表。
- 三次选择：安装器镜像、channel 镜像、二进制缓存优先级。
- 显示配置摘要。
- 回答 `n` 进入 `CONFIG_DIR`（默认 `/etc/nixos`）下的 shell 编辑 `configuration.nix`，`exit` 返回。
- 摘要重新读取文件内容，确认后开始安装。

## 方式二：外部模板

`--template=TYPE:PATH` 用外部文件替换内置模板，可重复指定。

| TYPE | 目标文件 | 用途 |
| --- | --- | --- |
| `configuration` | `/etc/nixos/configuration.nix` | 系统配置主体 |
| `hardware` | `/etc/nixos/hardware-configuration.nix` | 文件系统与引导 |
| `networking` | `/etc/nixos/networking.nix` | 静态网络 |

```bash
bash nixos-infect.sh --lang=zh \
  --template=configuration:/root/my-configuration.nix \
  --template=networking:/root/my-networking.nix
```

- `PATH` 是运行脚本的机器上的路径，文件不可读时立即报错退出。
- 模板里的 `@@NAME@@` 会被替换；去掉占位符直接写静态内容同样可行，脚本只做文本替换。
- 未指定 `--template` 的类型仍使用内置模板。

## 方式三：修改内置模板

- 内置模板在脚本 `SECTION 11`，共四段：`TMPL_CONFIGURATION`、`TMPL_HARDWARE_EFI`、`TMPL_HARDWARE_BIOS`、`TMPL_NETWORKING`。
- 直接编辑这些 `cat <<'TMPL_EOF'` 块，就改变了默认生成的内容。
- 改动随脚本分发，升级时需要重新合并，容易丢失；一般场景优先用外部模板。

## 占位符参考

### configuration 模板

| 占位符 | 含义 | 示例值 |
| --- | --- | --- |
| `@@HOSTNAME@@` | 原系统短主机名 | `VM-0-9-opencloudos` |
| `@@DOMAIN@@` | 原系统域名，通常为空 | `""` |
| `@@ZRAM@@` | 是否启用 zram swap | `true` |
| `@@NETWORK_IMPORT@@` | 是否导入 `networking.nix` | `./networking.nix` |
| `@@SUBSTITUTERS_BLOCK@@` | `nix.settings.substituters` 整块 | `nix.settings.substituters = [ ... ];` |
| `@@DEFAULT_CHANNEL@@` | `system.defaultChannel` 的 URL | `https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-25.11` |
| `@@AUTHORIZED_KEYS@@` | root 公钥，多行、每行带引号 | `"ssh-ed25519 AAAA... me@laptop"` |

### hardware 模板

| 占位符 | 含义 | 示例值 |
| --- | --- | --- |
| `@@ESP@@` | EFI 场景的 ESP 分区 | `/dev/disk/by-uuid/1234-ABCD` |
| `@@GRUBDEV@@` | BIOS 场景写 GRUB 的磁盘 | `/dev/vda` |
| `@@ROOTFSDEV@@` | 根文件系统设备 | `/dev/vda1` |
| `@@ROOTFSTYPE@@` | 根文件系统类型 | `ext4` |
| `@@SWAPCFG@@` | 已有 swap 分区时写入 | `swapDevices = [ { device = "/dev/vda2"; } ];` |
| `@@AVAILABLE_KERNEL_MODULES@@` | initrd 内核模块 | `"ata_piix" "uhci_hcd" "xen_blkfront"` |

### networking 模板

| 占位符 | 含义 | 示例值 |
| --- | --- | --- |
| `@@ETH0_NAME@@` | 默认路由所在网卡名 | `eth0` |
| `@@ETH0_IP4S@@` | IPv4 地址（Nix 属性列表） | `{ address="192.0.2.10"; prefixLength=24; }` |
| `@@ETH0_IP6S@@` | IPv6 地址，可能为空 | `{ address="2001:db8::10"; prefixLength=64; }` |
| `@@GATEWAY@@` | IPv4 默认网关 | `192.0.2.1` |
| `@@GATEWAY6@@` | IPv6 默认网关 | `2001:db8::1` |
| `@@ETHER0@@` | 网卡 MAC 地址 | `52:54:00:12:34:56` |
| `@@NAMESERVERS@@` | 取自 `/etc/resolv.conf` 的 DNS | `"8.8.8.8" "1.1.1.1"` |
| `@@PREDICTABLE_INAMES@@` | 网卡命名策略的强制设置 | `usePredictableInterfaceNames = lib.mkForce false;` |

## 常见定制示例

### 新增系统用户

```nix
users.users.alice = {
  isNormalUser = true;
  extraGroups = [ "wheel" ];
  openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA... alice@laptop" ];
};
```

- 加在 `configuration.nix` 顶层；`wheel` 组可执行 `sudo`，记得同时给用户设置密码（`passwd alice`）或配置公钥。

### 加入 flake 配置

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

- 加在 `configuration.nix` 顶层；脚本仍用 channel 构建系统，不会生成 `flake.nix`，迁移由你自行完成。

### 固定静态 IP

```nix
networking = {
  useDHCP = false;
  interfaces.eth0.ipv4.addresses = [
    { address = "192.0.2.10"; prefixLength = 24; }
  ];
  defaultGateway = "192.0.2.1";
  nameservers = [ "223.5.5.5" "119.29.29.29" ];
};
```

- 写在 `configuration.nix` 顶层；同时不要再导入生成的 `networking.nix`，二选一。
- 网卡名先用 `ip address show` 确认；也可让脚本生成 `networking.nix`（`--networking`）后再改。

### 追加 SSH 公钥

```nix
users.users.root.openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAA... ops@bastion"
  "ssh-ed25519 AAAA... old-key"
];
```

- 模板会从原系统 `authorized_keys` 生成整个列表，手工改写是整表覆盖；想保留旧公钥就把新行加进该列表，或在外部模板中保留 `@@AUTHORIZED_KEYS@@` 后再补。

### 替换 substituters 与 channel

```bash
NIX_SUBSTITUTERS="https://mirror.example.edu.cn/nix-channels/store" \
NIX_CHANNEL=nixos-25.11 \
NIX_CHANNEL_URL="https://mirror.example.edu.cn/nix-channels/nixos-25.11" \
bash nixos-infect.sh --lang=zh
```

- 环境变量优先于探测结果；`NIX_SUBSTITUTERS` 用空格分隔，脚本会去重并过滤 `cache.nixos.org`。只想固定 channel 版本时用 `--channel=nixos-25.11`。
- 转换完成后也可直接改 `configuration.nix`，再执行 `nixos-rebuild switch`：

```nix
nix.settings.substituters = [
  "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
  "https://mirror.nju.edu.cn/nix-channels/store"
];
system.defaultChannel = "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/nixos-25.11";
```

## 摘要为何以文件为准

- 交互模式里你可能在 shell 中改过 `configuration.nix`，摘要不能继续显示脚本内存中的旧值。
- 摘要用 `cfg_file_get` 回读 `networking.hostName`、`system.defaultChannel`，用 `cfg_file_substituters` 回读 substituters 列表；读不到才回退到探测值。
- 因此摘要就是即将安装的配置，不符就继续改，`exit` 后摘要会再次刷新。

## 相关文档

- [安装教程](./installation.md)
- [参数与环境变量参考](./cli.md)
- [镜像与探测](./mirrors.md)
- [工作原理](./how-it-works.md)
