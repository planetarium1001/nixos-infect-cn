# nixos-infect-cn

> ！作者注：这是使用AI辅助修改的第一版，还未在真实机器上完整测试，待测试结束以后再优化和定稿方案！

> 在国内云服务器上一键把 Debian/Ubuntu 转换为 NixOS，内置 USTC/TUNA/NJU 镜像，优先镜像可显式指定，其余自动回退。

本项目 fork 自 [elitak/nixos-infect](https://github.com/elitak/nixos-infect)，并参考了 [kidonng/nixos-infect-tuna](https://gist.github.com/kidonng/852ea559816420acaf33017c6e7ccf8b) 的 TUNA 补丁思路。

## ⚠️ 警告

- **会清空服务器磁盘**，请只在全新、无数据的机器上运行。
- **必须配置 SSH 密钥登录**，安装后 root 没有密码。
- 面向 **Debian 12** 及腾讯云轻量、阿里云 ECS 等 KVM 实例（尚未实测）。
- 网络默认识别 DHCP 实例；若实例使用静态 IP 且不在内置 provider 列表（DigitalOcean / Servarica / Hetzner Cloud / Webdock / Layer7 / Hostinger），需运行时加 `doNetConf=y` 或手动补 `networking.nix`。
- 不支持 OpenVZ/LXC。
- 作者不对数据丢失、服务器失联负责。

## ✨ 特性

- 国内 VPS 一键转 NixOS。
- 只使用 USTC、TUNA、NJU 三个国内镜像。
- 安装器（install）仅走 TUNA/NJU（USTC 不提供安装器，自动跳过）。
- NixOS channel 与二进制缓存（substituters）三家镜像均可用。
- `NIX_MIRROR` 显式指定优先镜像，失败后自动尝试其余镜像，全部失败回退官方源。
- 安装后镜像配置持久化到 `/etc/nixos/configuration.nix`。

## 🔧 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `NIX_MIRROR` | `auto` | `ustc`/`tuna`/`nju` 指定优先镜像；`auto` 用内置顺序 TUNA → USTC → NJU；`official` 完全走官方源 |
| `NIX_CHANNEL` | `nixos-26.05` | NixOS channel 名，同时决定生成的 `system.stateVersion` |
| `NIX_INSTALL_URL` | 空 | 覆盖 Nix 安装器地址（直接 `curl \| sh`） |
| `NIXOS_CONFIG` | `/etc/nixos/configuration.nix` | 若为 `http...` URL，会先下载为配置文件 |
| `NIXOS_IMPORT` | 空 | 额外 import 的 Nix 文件路径，如 `./host.nix` |
| `PROVIDER` | 自动探测 | 云厂商标识，如 `digitalocean` / `hetznercloud` / `hostinger` / `tencent` / `lightsail`。腾讯云（CVM/轻量）自动识别为 `tencent`，会额外开启 `ttyS0` 串口控制台 |
| `doNetConf` | 空 | 非空则运行时生成 `networking.nix`（静态网络场景） |
| `NO_SWAP` | 空 | 非空则跳过临时 swap 的创建与清理 |
| `NO_INFECT` | 空 | 非空则只生成配置、不执行安装 |
| `NO_REBOOT` | 空 | 非空则安装完不自动重启 |

## 🚀 快速开始

重装为 Debian 12，配置 SSH 密钥：

```bash
ssh-copy-id root@<服务器IP>
```

下载脚本：

```bash
curl -L https://raw.githubusercontent.com/planetarium1001/nixos-infect-cn/master/nixos-infect.sh -o nixos-infect.sh
# 国内网络可走加速：
# curl -L https://ghproxy.net/https://raw.githubusercontent.com/planetarium1001/nixos-infect-cn/master/nixos-infect.sh -o nixos-infect.sh
chmod +x nixos-infect.sh
```

运行（默认 `auto`，即 TUNA 优先）：

```bash
NIX_CHANNEL=nixos-26.05 bash -x nixos-infect.sh
```

指定优先镜像：

```bash
NIX_MIRROR=tuna     NIX_CHANNEL=nixos-26.05 bash -x nixos-infect.sh  # TUNA
NIX_MIRROR=nju      NIX_CHANNEL=nixos-26.05 bash -x nixos-infect.sh  # NJU
NIX_MIRROR=ustc     NIX_CHANNEL=nixos-26.05 bash -x nixos-infect.sh  # USTC（安装器自动回退 TUNA/NJU）
NIX_MIRROR=official NIX_CHANNEL=nixos-26.05 bash -x nixos-infect.sh  # 完全走官方源
```

完成后会自动重启。

## 🔧 安装后

```bash
nix-channel --list
nix config show | grep substituters
nixos-rebuild switch
```

## 🐛 排障 / 首次测试建议

脚本在重启前会做一次自检并打印汇总（PROVIDER、引导模式、根设备、ESP、NIXOS_LUSTRATE 内容等）：

- 若 `/etc/NIXOS_LUSTRATE` 为空或缺失 → 直接报错并**中止，不再重启**（避免重启后半死不活）。
- EFI 下若找不到 `EFI/BOOT/BOOT*.EFI`，或 BIOS 下 GRUB 设备不存在 → 打印 WARNING。

建议首次在**新机器**上分两步走：

```bash
# 第一步：只安装、不重启，先检查结果
NO_REBOOT=1 NIX_CHANNEL=nixos-26.05 bash -x nixos-infect.sh

# 检查安装产物
cat /etc/NIXOS_LUSTRATE
cat /etc/nixos/configuration.nix
ls -l /boot/EFI/BOOT/ 2>/dev/null || ls -l /boot/efi/EFI/BOOT/ 2>/dev/null
ls -l /nix/var/nix/profiles/system

# 第二步：确认无误后重启，并通过 VNC/串口抓取引导日志
reboot
```

重启后若仍无法 SSH，请提供 VNC/串口引导日志（从内核加载到 systemd 报错那一段），以便定位。

## 🙏 致谢

- [elitak/nixos-infect](https://github.com/elitak/nixos-infect)
- [kidonng/nixos-infect-tuna](https://gist.github.com/kidonng/852ea559816420acaf33017c6e7ccf8b)
- USTC、TUNA、NJU 镜像站

> 上游原始 README 见 [README.upstream.md](./README.upstream.md)。

## 📄 License

[GNU General Public License v3.0](./LICENSE)，与上游 elitak/nixos-infect 保持一致。
